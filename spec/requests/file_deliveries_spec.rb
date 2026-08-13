require "rails_helper"

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
