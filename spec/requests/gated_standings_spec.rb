require "rails_helper"

describe "standings on a gated game's page", type: :request do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }

  it "renders the finishing team's result" do
    pass    = create_access_pass(:game => game)
    started = 3.days.ago
    attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                  :game_run => nil, :access_pass => pass)
    attempt.update_columns(:created_at => started, :finished_at => started + 600)

    get game_path(game)

    expect(response.body).to include("Результаты")
    expect(response.body).to include(pass.team.name)
    # Finding 5: the standings are RANKED by duration, so the column must show
    # it exactly (00:10:00 for 600 seconds) rather than
    # distance_of_time_in_words' nearest-few-minutes bucketing, which renders
    # the same "около Х минут"/"около Х часов" text for attempts many minutes
    # apart -- a table sorted by the very thing the reader cannot distinguish.
    expect(response.body).to include(attempt.seconds_to_hms(attempt.duration))
    expect(response.body).to include("00:10:00")
  end

  it "does not render standings on a scheduled game's page" do
    scheduled = create_game(:is_draft => false, :access_mode => "scheduled")

    get game_path(scheduled)

    expect(response.body).not_to include("Результаты")
  end

  it "redirects the run-results page to the game page" do
    get game_passings_show_results_path(:game_id => game.id)

    expect(response).to redirect_to(game_path(game))
  end

  # Finding 4 of the whole-branch review: GamePassingsController rendered
  # show_results.html.erb directly (bypassing #show_results' own redirect
  # above) from show_current_level, post_answer, post_options and exit_game,
  # each with @run ||= @game.current_run -- a gated game's run has no
  # entrants, so a customer who just finished a paid game got "Поздравляем"
  # over an empty results table and no link to the standings that exist.
  # Driven through the real finishing move (post_answer with the level's own
  # code), not by stubbing finished? -- proves the fix fires on the actual
  # path a paying customer takes.
  #
  # As of the gated-finish screen (task 2 of that same effort),
  # render_finished_passing no longer redirects a gated game to game_path at
  # all -- it renders game_passings/gated_finish directly, carrying the
  # standings itself. This example now covers exactly that landing; the
  # game-page half of finding 4/6 (visiting game_path separately, where the
  # standings and the full-log link still have to appear) moved to the
  # example below it.
  it "lands a finishing team on the finish screen instead of an empty results table" do
    captain = create_user
    team    = create_team(:captain => captain)
    pass    = create_access_pass(:game => game, :team => team)

    put login_path, :params => { :email => captain.email, :password => "1234" }
    get show_current_level_path(:game_id => game.id)

    post post_answer_path(:game_id => game.id), :params => { :answer => level.correct_answer }

    expect(response).to have_http_status(:ok)
    expect(GamePassing.find_by(:access_pass_id => pass.id).finished?).to be true

    expect(response.body).to include(t("games.standings.title"))
    expect(response.body).to include(team.name)
    expect(response.body).not_to include(t("game_passings.show_results.congrats"))
  end

  # Finding 6 of the whole-branch review: full_log_visible? used to resolve
  # through game.current_run.passing_for, which a runless attempt
  # (game_run_id NULL) can never satisfy, so this link was false for every
  # gated attempt -- reachable only by typing show_full_log's URL directly,
  # even though LogsController#ensure_full_log_access already admitted this
  # exact player. This is the game-page half of finding 4/6: the finish
  # screen itself (example above) carries its own standings and needs no
  # separate game_path visit, but a finished team returning to the game page
  # later -- the ordinary way to check standings again -- must still see
  # both the standings and the link to their own full log.
  it "shows the standings and the finished team's full-log link on the game page" do
    captain = create_user
    team    = create_team(:captain => captain)
    create_access_pass(:game => game, :team => team)

    put login_path, :params => { :email => captain.email, :password => "1234" }
    get show_current_level_path(:game_id => game.id)
    post post_answer_path(:game_id => game.id), :params => { :answer => level.correct_answer }
    expect(response).to have_http_status(:ok)

    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(t("games.standings.title"))
    expect(response.body).to include(team.name)
    expect(response.body).to include(t("game_passings.show_results.full_log"))
    expect(response.body).to include(show_full_log_path(game))
  end

  # The companion cases to the example above: the link is per-CURRENT-USER,
  # not universally shown to every standings viewer.
  describe "the full-log link on a gated game's standings" do
    let(:captain) { create_user }
    let(:team)    { create_team(:captain => captain) }
    let!(:pass)   { create_access_pass(:game => game, :team => team) }
    let!(:attempt) do
      create_game_passing(:game => game, :team => team, :level => level,
                          :game_run => nil, :access_pass => pass)
    end

    it "hides the link from a guest" do
      attempt.update!(:finished_at => Time.now)

      get game_path(game)

      expect(response.body).not_to include(t("game_passings.show_results.full_log"))
    end

    it "hides the link while the team is still playing" do
      put login_path, :params => { :email => captain.email, :password => "1234" }

      get game_path(game)

      expect(response.body).not_to include(t("game_passings.show_results.full_log"))
    end
  end

  def t(key)
    I18n.t(key)
  end
end
