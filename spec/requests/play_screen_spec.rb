require "rails_helper"

describe "the play screen", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
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
  # more stressful. The bar is sticky rather than a row of a viewport-height
  # grid now, but this assertion is about the bar existing at all -- whether it
  # is actually ON SCREEN is a layout question no request spec can answer, and
  # is measured in a browser instead (bin/measure-play-screen).
  it "keeps the code field and the countdown in a bar of their own" do
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('class="playbar"')
  end

  # The options moved out of the bar and in with the question, which only works
  # because every control names the form by id instead of nesting inside it.
  # Drop the form: attribute and a quiz becomes unanswerable -- the browser and
  # Capybara alike submit nothing for a control that belongs to no form -- so
  # this pins the wiring rather than the placement.
  it "binds a quiz option to the answer form by id, not by nesting" do
    question = create_question(:level => level)
    create_option(:question => question, :text => "Первый", :is_correct => true)
    create_option(:question => question, :text => "Второй", :is_correct => false)

    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include('id="answer-form"')
    expect(response.body).to match(/<input[^>]*type="radio"[^>]*form="answer-form"/)
    # And the options are NOT inside the bar: the bar opens after them.
    expect(response.body.index('class="quiz-option"'))
      .to be < response.body.index('class="playbar"')
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
    ].each do |dom_id|
      expect(response.body.scan(%(id="#{dom_id}")).size).to eq(1),
        "expected exactly one ##{dom_id}; hints break silently if it is renamed, dropped or duplicated"
    end
  end

  # TICKET #83 regression test. Finishing the last level sets current_level to
  # nil (GamePassing#pass_level! -- `self.current_level = self.current_level.next`
  # returns nil off the last level) and stamps finished_at. Before
  # GamePassingsController#show_current_level's own `if @game_passing.finished?`
  # guard (game_passings_controller.rb:35-38) existed, GET-ing this page for a
  # finished team read current_level.something on a nil current_level and
  # 500'd -- refreshing the browser at game end broke it. #post_answer already
  # had the identical guard; GET simply never got it, in the Merb original as
  # much as here.
  #
  # This used to be covered only by Cucumber's "я обновляю страницу" step
  # (features/tickets/ticket-83(5).feature:38), and only as a side effect of
  # that step happening to issue a GET. Pinned here directly so the guard does
  # not depend on a Cucumber step definition's choice of HTTP verb.
  it "shows the results, not a 500, on GET after the game has finished" do
    passing.update!(:current_level => nil, :finished_at => Time.current)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("game_passings.show_results.congrats"))
  end
end
