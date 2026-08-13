require "rails_helper"

# Maps every example below to the row it exercises in §4's authorization
# table (docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md,
# "## 4. Serving and authorization" -- read the CURRENT text: the hint
# sub-clause of the "Playing team" row was amended in Task 2's fix round to
# document the passed-level exception). Kept here so coverage can be checked
# against the contract without cross-referencing prose.
#
# | §4 row                    | May fetch                                    | Covered by |
# |----------------------------|-----------------------------------------------|------------|
# | Game author, superadmin    | any file in the game                          | "serves the original to the game's author", "serves the original to a superadmin who is not the author", "serves the web variant to the game's author", "serves the thumb variant to the game's author" |
# | Playing team                | current level; already-passed levels; fired hints, and every hint on an already-passed level (fired or not) | "a playing team" describe block: "serves a file on the level the team is on" (current level), "404s for a file on a level the team has not reached" (negative boundary). The passed-level and hint-fired/hint-on-passed-level sub-clauses are NOT re-tested here -- they are the unit-level contract of GameFileAccess#level_visible?/#hint_visible? and are pinned directly, without an HTTP round trip, in spec/models/game_file_access_spec.rb (see that file and the class comment on GameFileAccess). |
# | Everyone else               | 404, never 403                                | "404s for a logged-out requester", "404s for a signed-in user with no connection to the game", "404s for a file id belonging to a different game" |
#
# Cross-cutting, not tied to one row (apply once a requester has already
# cleared the table above):
#   * the :variant whitelist (§4 intro, "matched against a hard-coded
#     whitelist before anything touches storage") -- "never routes a variant
#     name outside the whitelist", "keeps the route constraint and the
#     controller whitelist in agreement"
#   * "Response headers" subsection -- the "response headers" describe block
#   * design §3 invariant I1 (a read must never allocate disk) -- "the read
#     path never allocates disk (design invariant I1)" describe block
#   * design §3 invariant I3 (a missing blob is an expected state, not an exception),
#     Task 4 -- "a missing blob" describe block
describe "file delivery", :type => :request do
  # Defined here, not shared: Phase 2B's spec/requests/game_files_spec.rb
  # defines its own copy at line 4 and there is no shared request-spec login
  # helper in spec/spec_helpers/. Copy this shape verbatim -- create_user
  # generates the password "1234", which is what makes this work.
  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @file   = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
  end

  def deliver(variant = "original")
    get game_file_delivery_path(@game, @file, variant)
  end

  it "serves the original to the game's author" do
    login_as @author
    deliver

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(@file.byte_size)
  end

  it "serves the original to a superadmin who is not the author" do
    admin = create_user
    admin.update_column(:is_superadmin, true)

    login_as admin
    deliver

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(@file.byte_size)
  end

  it "serves the web variant to the game's author" do
    login_as @author
    deliver("web")

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(@file.existing_web_variant.blob.byte_size)
  end

  it "serves the thumb variant to the game's author" do
    login_as @author
    deliver("thumb")

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(@file.existing_thumb_variant.blob.byte_size)
  end

  it "404s for a logged-out requester" do
    deliver
    expect(response).to have_http_status(:not_found)
  end

  it "404s for a signed-in user with no connection to the game" do
    # 404, NOT 403: a 403 confirms the file exists, which tells an attacker
    # enumerating ids exactly which ones are real.
    login_as create_user
    deliver

    expect(response).to have_http_status(:not_found)
  end

  it "404s for a file id belonging to a different game" do
    other_game = create_game(:author => @author)
    other_file = GameFileUpload.new(other_game, fixture_upload("map.pdf"), @author).call

    login_as @author
    get game_file_delivery_path(@game, other_file, "original")

    expect(response).to have_http_status(:not_found)
  end

  it "never routes a variant name outside the whitelist" do
    # The route's own :constraints regex (config/routes.rb) is anchored to the
    # whole :variant segment -- confirmed via
    # Rails.application.routes.recognize_path, which raises RoutingError for
    # a single bad segment like "nope". So this can never reach
    # FileDeliveriesController#show at all: config.action_dispatch.show_exceptions
    # is :none in the test environment (config/environments/test.rb), so an
    # unmatched route raises here rather than rendering a 404 response -- there
    # is no HTTP-level response to assert :not_found against, only a routing
    # failure. This also means an HTTP request can never exercise the
    # controller's OWN VARIANTS.include? check as long as it lists the same
    # three values as this constraint -- see the drift-detection example below,
    # which pins that agreement directly instead of trying to observe its
    # absence over HTTP.
    login_as @author

    expect {
      get "/games/#{@game.id}/files/#{@file.id}/nope"
    }.to raise_error(ActionController::RoutingError)
  end

  # Not "never routes a path-traversal attempt through the :variant segment"
  # (formerly here, asserting the same RoutingError on
  # ".../../../../etc/passwd"): that string decomposes into five path
  # segments, and the route pattern "files/:id/:variant" only ever captures
  # one segment for :variant -- so it was rejected by ordinary segment-count
  # matching, before the :variant whitelist (route constraint OR controller
  # array) ever got a say. It could not fail for a drift in either whitelist,
  # so it proved nothing about them. The example below replaces it: it is a
  # direct assertion that the route constraint and the controller's array
  # cannot drift apart, which is the actual property worth guarding.
  it "keeps the route constraint and the controller whitelist in agreement" do
    route = Rails.application.routes.routes.find { |r| r.defaults[:controller] == "file_deliveries" }
    expect(route.requirements[:variant]).to eq(Regexp.union(FileDeliveriesController::VARIANTS))
  end

  describe "the read path never allocates disk (design invariant I1)" do
    # GameFile#web_variant / #thumb_variant call `.processed`, which GENERATES
    # the ActiveStorage::VariantRecord (runs libvips, writes to disk) when one
    # is absent. A delivery route built on those would let a GET run libvips
    # and write to disk -- see the design's invariant I1: the play screen
    # breaking mid-race on a near-full disk is exactly the scenario this
    # guards against. FileDeliveriesController must use the read-only
    # GameFile#existing_web_variant / #existing_thumb_variant instead, which
    # resolve an existing variant record and return nil rather than create
    # one.
    it "404s for a wiped thumb variant instead of regenerating it, and creates no record" do
      @file.file.blob.variant_records.destroy_all
      expect(@file.file.blob.variant_records.reload.count).to eq(0)

      login_as @author
      deliver("thumb")

      expect(response).to have_http_status(:not_found)
      expect(@file.file.blob.variant_records.reload.count).to eq(0)
    end

    it "404s for a wiped web variant instead of regenerating it, and creates no record" do
      @file.file.blob.variant_records.destroy_all
      expect(@file.file.blob.variant_records.reload.count).to eq(0)

      login_as @author
      deliver("web")

      expect(response).to have_http_status(:not_found)
      expect(@file.file.blob.variant_records.reload.count).to eq(0)
    end
  end

  describe "a missing blob (design §3, I3: an expected state, not an exception)" do
    # Files can vanish from disk without the GameFile row noticing: a database
    # restored without its storage volume, an interrupted upload, a
    # purge_orphans run against a stale row, a half-finished azcopy sync
    # (Phase 4). The wrong behaviour is a 500 on the play screen mid-game; the
    # right one is a 404 for that one file, logged, with the rest of the
    # level intact.
    it "404s, and does not 500, when the blob is gone from disk" do
      login_as @author
      # Delete the stored bytes while leaving every database row intact -- the
      # exact shape of a database restored without its storage volume. This is
      # what actually raises ActionController::MissingFile from send_file
      # (confirmed on this branch); it is a different code path from the purge
      # example below, which never reaches send_file at all.
      @file.file.blob.service.delete(@file.file.blob.key)

      deliver

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the variant's blob is gone but the original survives" do
      login_as @author
      variant = @file.thumb_variant
      variant.image.blob.service.delete(variant.image.blob.key)

      deliver("thumb")

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the attachment has been purged outright, not merely deleted from the service" do
      # A second, different path from "gone from disk" above. blob_for's
      # "original" branch returns file.file, an ActiveStorage::Attached::One,
      # which is NEVER nil -- so an attachment.nil? guard alone cannot catch
      # this. Measured on this branch before the #attached? check existed:
      # file.purge followed by this GET returned 200 with an EMPTY body, not
      # 404.
      login_as @author
      @file.file.purge

      deliver

      expect(response).to have_http_status(:not_found)
    end

    it "still serves a healthy file in the same game" do
      # The blast radius test: one dead file must not take the others with it.
      healthy = GameFileUpload.new(@game, fixture_upload("map.pdf"), @author).call
      login_as @author
      @file.file.blob.service.delete(@file.file.blob.key)

      get game_file_delivery_path(@game, healthy, "original")

      expect(response).to have_http_status(:ok)
    end
  end

  describe "response headers" do
    before(:each) { login_as @author }

    it "takes the content type from the stored column, not the filename" do
      # The filename says .png; the sniffed, stored value says jpeg (photo.jpg
      # really is a JPEG). The stored value wins. A Content-Type derived from
      # an author-supplied filename is how an "image" gets served as
      # text/html.
      @file.update_column(:filename, "photo.png")
      deliver

      expect(response.headers["Content-Type"]).to include("image/jpeg")
    end

    it "sets nosniff on a served file" do
      # Not a pin on this controller: nosniff comes from Rails' own
      # ActionDispatch::Response.default_headers, applied to every response
      # app-wide, before this controller's action ever runs. This and the
      # refusal example below pin the CONTRACT a MIME-sniffing browser
      # depends on -- that the header is actually present on what this
      # controller sends -- not any code here that produces it. (There isn't
      # any: a `before_action` used to set this header explicitly, and
      # removing it left both examples, and all 24 in this file, green.)
      deliver
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    end

    it "sets nosniff on a refusal too" do
      # A genuine 404, not a routing failure: an out-of-whitelist :variant
      # never reaches the controller at all (see "never routes a variant
      # name outside the whitelist" above, and the route :constraints regex
      # in config/routes.rb) -- there is no response to assert a header on
      # for that case. This exercises the controller's own head(:not_found)
      # instead, via a file id that does not exist. Same CONTRACT pin as
      # above, not a controller-specific one -- see that example's comment.
      get game_file_delivery_path(@game, -1, "original")

      expect(response).to have_http_status(:not_found)
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    end

    it "forces a PDF to download" do
      pdf = GameFileUpload.new(@game, fixture_upload("map.pdf"), @author).call
      get game_file_delivery_path(@game, pdf, "original")

      expect(response.headers["Content-Disposition"]).to start_with("attachment")
    end

    it "serves an image inline" do
      deliver
      expect(response.headers["Content-Disposition"]).to start_with("inline")
    end

    it "RFC 5987-encodes a Cyrillic filename" do
      # The literal percent-encoded bytes, not just the parameter's presence:
      # "filename*=UTF-8''" alone is satisfied by ANY value at all -- a future
      # change that sanitises or transliterates the filename (e.g. via
      # ActiveSupport::Inflector.transliterate, producing
      # "filename*=UTF-8''shema%20otelya.jpg") would still match that fragment
      # and this spec would stay green while every player's download name
      # came out mangled. Computed once via actionpack's own
      # ActionDispatch::Http::ContentDisposition::RFC_5987_ESCAPED_CHAR
      # pattern against "схема.jpg" (UTF-8 percent-escaped, uppercase hex),
      # not hand-derived -- confirmed against a real response before being
      # pinned here.
      @file.update_column(:filename, "схема.jpg")
      deliver

      expect(response.headers["Content-Disposition"])
        .to include("filename*=UTF-8''%D1%81%D1%85%D0%B5%D0%BC%D0%B0.jpg")
    end

    it "marks the response private, never public" do
      # The one header whose mistake is invisible in every local test and
      # catastrophic behind a shared cache: a `public` response to an
      # authorized request can be replayed by the proxy to someone who never
      # passed the §4 authorization check.
      deliver

      expect(response.headers["Cache-Control"]).to include("private")
      expect(response.headers["Cache-Control"]).not_to include("public")
    end

    it "answers 304 to a conditional request carrying the same ETag" do
      deliver
      etag = response.headers["ETag"]

      get game_file_delivery_path(@game, @file, "original"), :headers => { "If-None-Match" => etag }

      expect(response).to have_http_status(:not_modified)
      expect(response.body).to be_empty
    end

    it "pins max-age on both a 200 and a 304" do
      # Deleting the explicit Cache-Control line entirely survives the
      # "marks the response private" example above -- stale?(:public =>
      # false) alone yields "max-age=0, private, must-revalidate", which
      # still contains "private" and still excludes "public". That example
      # guards the security half of the contract; this one guards the
      # performance half it leaves unguarded: the actual max-age=3600 this
      # host relies on to avoid a conditional round trip per image on every
      # later view of the play screen.
      #
      # And a 200 alone isn't enough either: max-age has to survive
      # revalidation too, or every second-and-later view degrades to a
      # conditional request regardless of what the first response promised.
      # A version of the controller that set Cache-Control on
      # response.headers AFTER stale?'s early return -- rather than passing
      # :cache_control into stale? itself -- passed the 200 half of this
      # example and failed the 304 half, because that line never executes on
      # the path stale? takes for a 304.
      deliver
      expect(response.headers["Cache-Control"]).to include("max-age=3600")
      etag = response.headers["ETag"]

      get game_file_delivery_path(@game, @file, "original"), :headers => { "If-None-Match" => etag }

      expect(response).to have_http_status(:not_modified)
      expect(response.headers["Cache-Control"]).to include("max-age=3600")
      expect(response.headers["Cache-Control"]).to include("private")
    end

    it "gives a variant a different ETag from the original" do
      # The trap: an ETag built from the checksum alone is identical across
      # variants, so a client holding the 320px thumbnail is told its copy of
      # the full-size original is fresh -- and renders the thumbnail
      # everywhere.
      deliver
      original_etag = response.headers["ETag"]

      get game_file_delivery_path(@game, @file, "thumb")

      expect(response.headers["ETag"]).not_to eq(original_etag)
    end

    it "delivers the original byte-for-byte" do
      # Against the stored blob, not the raw fixture: the upload pipeline
      # canonicalises images (strips EXIF/GPS, see design §2), so the bytes
      # actually served are not expected to equal spec/fixtures/files/photo.jpg.
      expected = @file.file.download
      deliver

      expect(response.body.bytesize).to eq(expected.bytesize)
      expect(response.body).to eq(expected)
    end

    it "delivers the thumb variant byte-for-byte against the stored blob" do
      deliver("thumb")

      expected = @file.existing_thumb_variant.download
      expect(response.body.bytesize).to eq(expected.bytesize)
      expect(response.body).to eq(expected)
    end
  end

  describe "a playing team" do
    before(:each) do
      @team_user = create_user
      @team = create_team(:members => [ @team_user ])
      @team_user.reload
      @l1 = create_level(:game => @game, :name => "L1")
      @l2 = create_level(:game => @game, :name => "L2")
      @passing = create_game_passing(:level => @l1, :team => @team)
    end

    it "serves a file on the level the team is on" do
      FileAttachment.create!(:game_file => @file, :attachable => @l1)
      login_as @team_user
      deliver

      expect(response).to have_http_status(:ok)
    end

    it "404s for a file on a level the team has not reached" do
      FileAttachment.create!(:game_file => @file, :attachable => @l2)
      login_as @team_user
      deliver

      expect(response).to have_http_status(:not_found)
    end
  end
end
