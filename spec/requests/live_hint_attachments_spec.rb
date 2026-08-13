require "rails_helper"

# Task 3 put attached photographs on the play screen for hints that had
# ALREADY fired at page load (shared/_attachment_strip.html.erb, rendered by
# show_current_level.html.erb). A hint that fires AFTER page load never goes
# through that render at all -- level_hint_updater.js polls
# GamePassingsController#get_current_level_tip and injects the JSON straight
# into the DOM. This spec is the server-side half of making that hint carry
# the same photographs, under the same authorization gate
# (GameFileAccess#permitted?) the page-load render uses.
#
# The DOM-injection half -- that the JSON is built into <img>/<a> nodes via
# createElement/setAttribute, never through innerHTML or string
# concatenation -- is covered by reading public/javascripts/level_hint_updater.js
# and by spec/assets/level_hint_updater_spec.rb's source guard. This suite
# has no JS runner, so it cannot prove the DOM sink is safe; what it CAN prove
# is that the wire payload carries the filename as plain JSON data, escaped
# like any other string, never as markup -- see the last example below.
describe "attachments on the live hint poller", :type => :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }
  let(:player) do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  before do
    passing
    sign_in(player)
  end

  it "includes the fired hint's attachments, at the delivery route's web-variant path" do
    hint = create_hint(:level => level, :delay => 0, :text => "hint text") # fires immediately
    image = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
    expect(image).to be_persisted
    hint.replace_attached_files([ image.id ], nil)

    get get_current_level_tip_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body["attachments"]).to be_an(Array)
    expect(body["attachments"].length).to eq(1)
    attachment = body["attachments"].first
    expect(attachment["alt"]).to eq(image.filename)
    expect(attachment["url"]).to eq(game_file_delivery_path(game, image, "original"))
    expect(attachment["image_url"]).to eq(game_file_delivery_path(game, image, "web"))
  end

  it "degrades a PDF (no web variant) to a generic entry, never a broken image_url" do
    hint = create_hint(:level => level, :delay => 0, :text => "hint text")
    pdf = GameFileUpload.new(game, fixture_upload("map.pdf"), author).call
    expect(pdf).to be_persisted
    hint.replace_attached_files([ pdf.id ], nil)

    get get_current_level_tip_path(:game_id => game.id)

    body = JSON.parse(response.body)
    attachment = body["attachments"].first
    expect(attachment["alt"]).to eq(pdf.filename)
    expect(attachment["url"]).to eq(game_file_delivery_path(game, pdf, "original"))
    expect(attachment["image_url"]).to be_nil
  end

  it "does NOT include an unfired hint's attachments -- a hint's files become visible exactly when the hint does" do
    fired_hint   = create_hint(:level => level, :delay => 0,    :text => "fired")     # fires immediately
    unfired_hint = create_hint(:level => level, :delay => 3600, :text => "unfired")   # far in the future

    fired_file   = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
    unfired_file = GameFileUpload.new(game, fixture_upload("small.png"), author).call
    fired_hint.replace_attached_files([ fired_file.id ], nil)
    unfired_hint.replace_attached_files([ unfired_file.id ], nil)

    get get_current_level_tip_path(:game_id => game.id)

    body = JSON.parse(response.body)
    filenames = body["attachments"].map { |a| a["alt"] }

    expect(filenames).to include(fired_file.filename)
    expect(filenames).not_to include(unfired_file.filename)
    # Belt and braces: the unfired file's name must not leak anywhere in the
    # wire body at all, not just outside the "attachments" key.
    expect(response.body).not_to include(unfired_file.filename)
  end

  it "does NOT include a file belonging to a different game, even if a corrupted row attaches it directly" do
    # FileAttachment#file_belongs_to_the_same_game already refuses this at
    # create time (spec/models/file_attachment_spec.rb) -- so a normal
    # replace_attached_files call can never produce this row. Bypassing
    # validation here proves the SERVER'S authorization gate
    # (GameFileAccess#permitted?, asked by the controller for every file)
    # is the thing actually keeping a foreign file out of the payload, as
    # defence in depth -- not merely that nothing in the UI offers one.
    hint = create_hint(:level => level, :delay => 0, :text => "hint text")
    other_game = create_game(:author => author, :is_draft => false)
    foreign_file = GameFileUpload.new(other_game, fixture_upload("photo.jpg"), author).call

    attachment = FileAttachment.new(:game_file => foreign_file, :attachable => hint, :locale => nil)
    attachment.save(:validate => false)

    get get_current_level_tip_path(:game_id => game.id)

    body = JSON.parse(response.body)
    expect(body["attachments"]).to eq([])
    expect(response.body).not_to include(foreign_file.filename)
  end

  it "round-trips a filename containing markup as escaped JSON data, never unescaped in the wire body" do
    hint = create_hint(:level => level, :delay => 0, :text => "hint text")
    malicious_name = '"><img src=x onerror=alert(1)>.jpg'
    image = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
    image.update!(:filename => malicious_name)
    hint.replace_attached_files([ image.id ], nil)

    get get_current_level_tip_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)

    # config.load_defaults 8.0 turns on escape_html_entities_in_json, so "<"
    # travels over the wire as "<" -- the RAW markup string must never
    # appear unescaped in the body Rails actually sent.
    expect(response.body).not_to include("<img src=x onerror=alert(1)>")

    # JSON.parse restores the escaped sequence to the literal character
    # before any application code (or level_hint_updater.js) sees it -- this
    # is the "correctly escaped JSON data" half of the XSS proof. The other
    # half -- that the DOM sink never re-parses it as markup -- is not
    # something this HTTP-level suite can execute; see the file comment.
    body = JSON.parse(response.body)
    expect(body["attachments"].first["alt"]).to eq(malicious_name)
  end

  it "includes the platform hint label translated for the interface locale, not a hardcoded literal" do
    create_hint(:level => level, :delay => 0, :text => "hint text")

    get get_current_level_tip_path(:game_id => game.id)

    body = JSON.parse(response.body)
    expect(body["hint_label"]).to eq(I18n.t("game_passings.show_current_level.hint_label"))
  end
end
