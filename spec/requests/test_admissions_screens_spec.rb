require "rails_helper"

describe "the test-run screens", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    # The author plays their own test through their own team -- create_user
    # makes none, and may_start_passing? returns false on a nil @team before it
    # ever reaches the is_testing? exemption. features/games/test-game-1.feature
    # sets this up the same way ("пользователь Author создает команду").
    author.update!(:team => create_team(:captain => author))
    sign_in(author)
    post start_test_game_path(game)
    game.reload
  end

  it "shows the admissions panel to the author of a testing game" do
    get game_path(game)

    response.body.should include("Допуск к тестированию")
  end

  it "shows the link" do
    get game_path(game)

    response.body.should include(game.reload.current_run.test_token)
  end

  it "lists an admitted team with a revoke button" do
    team = create_team(:captain => create_user)
    create_test_admission(:run => game.current_run, :team => team)

    get game_path(game)

    response.body.should include(team.name)
    response.body.should include(revoke_test_admission_path(:game_id => game.id,
                                                            :id => TestAdmission.last.id))
  end

  it "hides the panel once the test is finished" do
    post finish_test_game_path(game)

    get game_path(game)

    response.body.should_not include("Допуск к тестированию")
  end

  it "offers a teamless tester a way into the game from the dashboard" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)

    delete logout_path
    sign_in(tester)
    get dashboard_path

    response.body.should include(game.name)
    response.body.should include(show_current_level_path(:game_id => game.id))
  end

  # Scoped to the test-runs section rather than the whole page. A testing game
  # is not a draft, so it is `visible` and appears in dashboard/_coming_games
  # for the 0.1s between start_test's `starts_at = Time.now + 0.1.second` and
  # that moment passing -- pre-existing, unrelated to admissions, and asserting
  # on the whole body would make this example a clock race.
  it "shows a teamless tester nothing when they hold no admission" do
    delete logout_path
    sign_in(create_user)

    get dashboard_path

    response.body.should_not include("Тестирование")
    response.body.should_not include(show_current_level_path(:game_id => game.id))
  end

  it "hides the exit control from a teamless solo tester" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)

    response.body.should_not include(exit_game_path(:game_id => game.id))
  end

  # finish_test deletes every passing and log line in the run and is behind
  # ensure_author. Offering its button to a tester is a 401 waiting to happen --
  # invisible until this feature put somebody other than the author in a test.
  it "hides the finish-testing button from a tester" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)

    response.body.should_not include(finish_test_game_path(game))
  end

  it "still shows the finish-testing button to the author" do
    get show_current_level_path(:game_id => game.id)

    response.body.should include(finish_test_game_path(game))
  end
end
