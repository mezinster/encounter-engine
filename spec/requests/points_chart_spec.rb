require "rails_helper"

describe "the points chart", type: :request do
  let(:viewer) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def scoring_game
    game  = create_game(:points_enabled => true, :level_completion_points => 10,
                        :game_completion_points => 50)
    level = create_level(:game => game, :position => 1)
    [ game, level ]
  end

  it "shows a team's balance" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    sign_in(viewer)

    get teams_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(passing.team.name)
    expect(response.body).to include("10")
  end

  it "shows a team with no transactions at zero rather than omitting it" do
    team = create_team(:captain => create_user)
    sign_in(viewer)

    get teams_path

    expect(response.body).to include(team.name)
  end

  it "breaks ties on name, so an all-zero chart is alphabetical" do
    # create_team IGNORES a :name option -- it always generates "Team#<random>"
    # -- so the names are set afterwards. Passing :name to the helper would
    # leave two random names and an assertion that proves nothing.
    b = create_team(:captain => create_user); b.update!(:name => "Бета")
    a = create_team(:captain => create_user); a.update!(:name => "Альфа")
    sign_in(viewer)

    get teams_path

    expect(response.body.index(a.name)).to be < response.body.index(b.name)
  end

  it "sorts by balance, highest first" do
    game, level = scoring_game
    poor = create_game_passing(:game => game, :level => level)
    rich = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => poor, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => rich, :reason => "level_completed",
                            :level => level, :amount => 90)
    sign_in(viewer)

    get teams_path

    expect(response.body.index(rich.team.name)).to be < response.body.index(poor.team.name)
  end

  it "counts deductions against the balance" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => passing, :reason => "game_completed",
                            :level => nil, :amount => -4)
    sign_in(viewer)

    get teams_path

    expect(response.body).to include("6")
  end

  # The chart's figures must be grouped queries. This programme has introduced
  # the same N+1 three times; the existing slope guard in teams_index_spec.rb
  # is what catches a fourth.
  it "keeps the query count flat as the number of teams grows" do
    game, level = scoring_game
    sign_in(viewer)
    2.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level)) }
    small = count_queries { get teams_path }

    6.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level)) }
    large = count_queries { get teams_path }

    expect(large).to eq(small)
  end
end
