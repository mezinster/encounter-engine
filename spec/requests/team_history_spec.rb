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

  it "lists the games the team has played, with what each was worth" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)

    get team_path(passing.team)

    expect(response.body).to include(game.name)
    expect(response.body).to include("10")
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
