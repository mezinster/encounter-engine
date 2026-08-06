require "rails_helper"

describe "the play screen", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }
  # An upcoming hint, so the countdown -- and not the "no more hints" text --
  # is what renders; #LevelHintCountdownContainer only exists in that branch.
  let(:hint)    { create_hint(:level => level, :delay => 600) }
  let(:player)  do
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

  # The code field is the thing players came to use, and task text plus
  # accumulating hints otherwise push it further down exactly as the game gets
  # more stressful.
  it "pins the code field, the countdown and the newest hint" do
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('class="playbar"')
  end

  # A phone helpfully capitalising or autocorrecting a code is a real way to
  # lose a game. Server-side matching is already case-insensitive; this is the
  # other half.
  it "stops the keyboard mangling a code" do
    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include('autocapitalize="off"')
    expect(response.body).to include('autocorrect="off"')
    expect(response.body).to include('spellcheck="false"')
  end

  # Codes are refused while paused, so a field that still looks usable is a
  # lie. The bar shows the pause instead.
  it "replaces the bar with the pause notice when paused" do
    game.pause!

    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include(I18n.t("game_passings.paused"))
    expect(response.body).not_to include('class="playbar-form"')
  end

  # The hint poller finds these by id and nothing else does. A request spec
  # cannot run level_hint_updater.js, so this catches only half the risk --
  # a rename in the template, not one in the JavaScript. That half is the
  # likely one: the template gets restructured, the poller rarely does.
  #
  # Exactly once each: getElementById and jQuery's #id both take the first
  # match, so a duplicate id is as broken as a missing one, and duplicates
  # are precisely what moving markup around creates.
  it "keeps every id the hint poller writes into, exactly once" do
    get show_current_level_path(:game_id => game.id)

    %w[
      LevelHintsContainer
      LevelHintCountdownContainer
      LevelHintCountdownTimerText
      LevelHintCountdownLoadIndicator
      PlaybarHint
      PlaybarHintText
    ].each do |dom_id|
      expect(response.body.scan(%(id="#{dom_id}")).size).to eq(1),
        "expected exactly one ##{dom_id}; hints break silently if it is renamed, dropped or duplicated"
    end
  end
end
