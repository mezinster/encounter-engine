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

  it "does not concatenate untrusted data into an HTML string" do
    # Identifier-agnostic, deliberately: an earlier version of every regex
    # below was anchored to the literal variable name `hintText`. That left
    # a hole exactly at the new attack surface the attachments feature
    # added -- `attachment.alt` (an author-supplied filename, exactly as
    # untrusted as hintText) is never mentioned by name in any of these
    # patterns, so a mutation collapsing the icon/filename spans into one
    # unsafe write --
    #   filenameSpan.innerHTML = "<b>" + attachment.alt + "</b>"
    # -- left all 11 examples in this file green. These guards instead
    # forbid the SINK outright, no matter which variable feeds it: any
    # innerHTML/outerHTML assignment at all, and any of jQuery's
    # markup-mutating methods fed string concatenation. A future untrusted
    # value -- a level title, a team name, anything else this function ever
    # grows to render -- is covered the same way without this file needing
    # another line.
    #
    # Bounded by the statement terminator, not the first ")" -- a naive
    # [^)]*  gives up as soon as it meets any nested call's own closing paren,
    # e.g. append(wrapper() + x) would slip straight past it.
    expect(source).not_to match(/(?:inner|outer)HTML\s*=/)
    expect(source).not_to match(/\.(?:append|html|prepend|after|before)\([^;]*\+/)
    expect(source).not_to match(/\$\(\s*["'][^"']*["']\s*\+/)
  end

  it "builds the hint node as text" do
    # Anchored to the whole statement, not a bare substring: "createTextNode
    # (hintText)" alone would still match if this line were deleted and only
    # a comment mentioning it survived -- see the class comment above, which
    # narrates this exact code for seven lines.
    expect(source).to match(/^\s*fieldset\.appendChild\(document\.createTextNode\(hintText\)\);\s*$/)
  end

  it "keeps the pinned playbar hint on textContent" do
    expect(source).to match(/^\s*pinnedText\.textContent = hintText;\s*$/)
  end
end

# Task 3's brief calls for a manual browser check (create a hint containing
# markup, watch it render as text with no alert firing) as the only proof the
# poller still works end to end. No browser is available in this environment,
# so that step is skipped here and left to a human with one. What follows
# instead is what a request spec CAN prove without a JS runner: the play
# screen still wires in the fixed script, and the JSON contract the fix
# depends on has not moved. With config.load_defaults 8.0,
# escape_html_entities_in_json is on, so the wire body itself may carry an
# escaped "<" -- but JSON.parse restores the literal character before the
# value reaches application code, which is what the assertion below checks.
# No HTML-escaping happens at this layer either before or after the fix;
# that responsibility now belongs solely to the DOM sink in
# level_hint_updater.js. Setup mirrors spec/requests/play_screen_spec.rb.
describe "the live hint poller's server-side contract", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
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
    # The parsed value must equal the raw author text, with no HTML-escaping
    # applied at this layer: escaping belongs solely to the DOM sink in
    # level_hint_updater.js. If the controller ever escaped this, the
    # ERB-rendered path (which already escapes) would double-escape.
    expect(body["hint_text"]).to eq(hint_text)
  end
end
