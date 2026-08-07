require "rails_helper"

# public/javascripts/level_hint_updater.js injects hint text that arrives from
# GamePassingsController#get_current_level_tip. Hint text is author-written
# free text and any registered user can become an author, so it is untrusted.
# jQuery .append() with a STRING parses it as markup (and jQuery 1.3.2 evals
# any <script> it finds), which made every hint a stored-XSS vector against
# every playing team. There is no JS runner in this suite, so this is a source
# guard, not a behavioural test.
describe "the level hint updater", type: :model do
  let(:source) { Rails.root.join("public/javascripts/level_hint_updater.js").read }

  it "does not concatenate hint text into an HTML string" do
    expect(source).not_to match(/append\([^)]*\+\s*hintText/)
    expect(source).not_to include("</legend>' + hintText")
  end

  it "builds the hint node as text" do
    expect(source).to include("createTextNode(hintText)")
  end

  it "keeps the pinned playbar hint on textContent" do
    expect(source).to include("pinnedText.textContent = hintText")
  end
end

# Task 3's brief calls for a manual browser check (create a hint containing
# markup, watch it render as text with no alert firing) as the only proof the
# poller still works end to end. No browser is available in this environment,
# so that step is skipped here and left to a human with one. What follows
# instead is what a request spec CAN prove without a JS runner: the play
# screen still wires in the fixed script, and the JSON contract the fix
# depends on -- the server keeps sending raw, unescaped hint text; escaping
# now happens only at the DOM sink in level_hint_updater.js -- has not moved.
# Setup mirrors spec/requests/play_screen_spec.rb.
describe "the live hint poller's server-side contract", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }
  let(:hint_text) { '<img src=x onerror="alert(1)">' }
  # delay: 0 puts the hint straight into hints_to_show, so the very first poll
  # to /play/:game_id/tip returns hint_text -- the "hint unlocks while the
  # page is open" path the brief says a manual pre-fix check reports as safe.
  let(:hint) { create_hint(:level => level, :delay => 0, :text => hint_text) }
  let(:player) do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  before do
    passing
    hint
    put login_path, :params => { :email => player.email, :password => "1234" }
  end

  it "still loads level_hint_updater.js on the play screen" do
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('src="/javascripts/level_hint_updater.js"')
  end

  it "still returns hint_num, hint_text and next_available_in, with hint_text unescaped" do
    get get_current_level_tip_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body).to have_key("hint_num")
    expect(body).to have_key("hint_text")
    expect(body).to have_key("next_available_in")
    # Unescaped on the wire is correct and must stay that way: escaping moves
    # to the DOM sink in level_hint_updater.js, not the JSON payload. If the
    # controller ever escaped this, the ERB-rendered path (which already
    # escapes) would double-escape.
    expect(body["hint_text"]).to eq(hint_text)
  end
end
