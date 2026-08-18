require "rails_helper"

describe "a team's history", type: :request do
  def scoring_game
    game  = create_game(:points_enabled => true, :level_completion_points => 10,
                        :game_completion_points => 50)
    level = create_level(:game => game, :position => 1)
    [ game, level ]
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "is reachable and names the team" do
    team = create_team(:captain => create_user)

    get team_path(team)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(team.name)
  end

  # Two awards on the same attempt (10 + 50 = 60) rather than one, and the
  # assertion is on the SUM, a number that appears nowhere else on the page --
  # each individual ledger row below still reads 10 and 50, never 60. A
  # second, unrelated game_passing for the same team makes sure the balance
  # line at the top (the team's GRAND total, 65) differs from this game's own
  # summary total (60) too -- otherwise "60" could pass by coincidence with a
  # single-game team, since balance and per-game total would be identical. A
  # test that instead asserted on "10" would pass even with @per_attempt
  # zeroed out, or with the @passings loop disabled entirely, because the
  # itemised ledger table renders that same "10" independently -- caught by
  # review.
  it "lists the games the team has played, with what each was worth" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => passing, :reason => "game_completed",
                            :amount => 50)

    other_game, other_level = scoring_game
    other_passing = create_game_passing(:game => other_game, :level => other_level,
                                        :team => passing.team)
    PointTransaction.award!(:passing => other_passing, :reason => "level_completed",
                            :level => other_level, :amount => 5)

    get team_path(passing.team)

    expect(response.body).to include(game.name)
    expect(response.body).to include("60")
  end

  # P9: the whole ledger is public, itemised rows included.
  it "shows the itemised ledger to a signed-out visitor" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)

    get team_path(passing.team)

    expect(response.body).to include("Очко за уровень")
  end

  it "shows a team with no history without erroring" do
    team = create_team(:captain => create_user)

    get team_path(team)

    expect(response).to have_http_status(:ok)
  end

  # A team can hold only one game_passing per game run
  # (index_game_passings_on_team_id_and_game_run_id is unique), so a single
  # team's history grows across DISTINCT games, not repeated attempts at the
  # same one -- each iteration below builds its own scoring_game rather than
  # reusing one, unlike the brief's literal text. See task-5-report.md.
  # --- Whose games this public page may name (F1) -------------------------
  #
  # The page is public by P9, which published the LEDGER. Game identity is
  # gated everywhere else in the app, so a game the viewer could not open
  # through games#show must not be named here either. The literal Russian is
  # asserted rather than I18n.t(...): `include(I18n.t(key))` cannot fail on a
  # missing key, because both sides would then be the same fallback string.

  def hidden_game_with_award(attrs)
    game  = create_game({ :points_enabled => true, :level_completion_points => 10,
                          :game_completion_points => 50 }.merge(attrs))
    level = create_level(:game => game, :position => 1)
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    [ game, passing ]
  end

  it "does not name a draft game to a signed-out visitor" do
    game, passing = hidden_game_with_award(:is_draft => true)

    get team_path(passing.team)

    expect(Game.visible).not_to include(game)
    expect(response.body).not_to include(game.name)
    expect(response.body).to include("Скрытая игра")
  end

  it "does not name a withdrawn game to a signed-out visitor" do
    game, passing = hidden_game_with_award({})
    game.update_column(:withdrawn_at, Time.now)

    get team_path(passing.team)

    expect(Game.visible).not_to include(game.reload)
    expect(response.body).not_to include(game.name)
    expect(response.body).to include("Скрытая игра")
  end

  # Scenario 1 of the review: an author admits a team to rehearse an
  # unreleased game. The rehearsal writes no ledger row, but the games table
  # lists the passing regardless of points, and that was enough to publish the
  # title.
  it "does not name a game that is being test-run" do
    game, level = scoring_game
    game.current_run.update_column(:is_testing, true)
    create_game_passing(:game => game, :level => level).tap do |passing|
      get team_path(passing.team)
    end

    expect(Game.visible).not_to include(game)
    expect(response.body).not_to include(game.name)
    expect(response.body).to include("Скрытая игра")
  end

  # The row STAYS. Dropping it would make the published balance stop equalling
  # the sum of the published rows, which reads as a bug in the chart -- the
  # one thing an itemised public ledger exists to rule out.
  it "still counts a hidden game's points toward the totals on show" do
    _game, passing = hidden_game_with_award(:is_draft => true)
    PointTransaction.award!(:passing => passing, :reason => "game_completed",
                            :amount => 50)

    get team_path(passing.team)

    # The balance line, this attempt's own total, and both itemised rows.
    expect(passing.team.balance).to eq(60)
    expect(response.body).to include("60")
    expect(response.body).to include("Очко за уровень")
    expect(response.body).to include("Очко за прохождение")
  end

  it "names a draft game to its own author" do
    game, passing = hidden_game_with_award(:is_draft => true)
    sign_in(game.author)

    get team_path(passing.team)

    expect(response.body).to include(game.name)
  end

  it "still hides a draft game from a signed-in stranger" do
    game, passing = hidden_game_with_award(:is_draft => true)
    sign_in(create_user)

    get team_path(passing.team)

    expect(response.body).not_to include(game.name)
  end

  # Copied from SecurityFilters#ensure_author rather than invented: a
  # superadmin reads any game, an operator only a GATED one.
  it "names a draft game to a superadmin" do
    game, passing = hidden_game_with_award(:is_draft => true)
    admin = create_user
    admin.update!(:is_superadmin => true)
    sign_in(admin)

    get team_path(passing.team)

    expect(response.body).to include(game.name)
  end

  it "names a draft GATED game to an operator but leaves an ordinary one hidden" do
    gated, gated_passing = hidden_game_with_award(:is_draft => true,
                                                  :access_mode => "pass_required")
    ordinary, = hidden_game_with_award(:is_draft => true)
    other = create_game_passing(:game => ordinary,
                                :level => ordinary.levels.first,
                                :team => gated_passing.team)
    PointTransaction.award!(:passing => other, :reason => "level_completed",
                            :level => ordinary.levels.first, :amount => 10)

    operator = create_user
    operator.update!(:is_operator => true)
    sign_in(operator)

    get team_path(gated_passing.team)

    expect(response.body).to include(gated.name)
    expect(response.body).not_to include(ordinary.name)
  end

  # --- One notion of "finished" (F2) --------------------------------------
  #
  # exit! stamps finished_at AND status "exited". Asking finished_at alone
  # printed a finish time here while the chart, asking GamePassing.completed,
  # counted the same row as never completed.
  #
  # Asserted on the "Финиш" CELL, not on the page: the "Начало" cell renders
  # created_at through the very same :long format, and on a row created in
  # this example the two strings are identical to the minute -- a page-wide
  # `not_to include` would be satisfied (or defeated) by the wrong cell.
  def finish_cell
    response.body[/data-label="Финиш">(.*?)<\/td>/m]
  end

  it "shows an exited run as abandoned rather than stamping it finished" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    passing.exit!

    get team_path(passing.team)

    expect(passing.reload.finished_at).not_to be_nil
    expect(finish_cell).to include("прервана")
    expect(finish_cell).not_to include(I18n.l(passing.finished_at, :format => :long))
  end

  it "still stamps a genuinely finished run with its finish time" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    passing.update!(:finished_at => Time.now)

    get team_path(passing.team)

    expect(finish_cell).to include(I18n.l(passing.reload.finished_at, :format => :long))
    expect(finish_cell).not_to include("прервана")
  end

  it "keeps the query count flat as the team's history grows" do
    team = create_team(:captain => create_user)
    2.times do
      game, level = scoring_game
      create_point_transaction(:passing => create_game_passing(:game => game, :level => level, :team => team))
    end
    small = count_queries { get team_path(team) }

    6.times do
      game, level = scoring_game
      create_point_transaction(:passing => create_game_passing(:game => game, :level => level, :team => team))
    end
    large = count_queries { get team_path(team) }

    expect(large).to eq(small)
  end
end
