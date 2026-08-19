require "rails_helper"

describe "an operator skipping a level for a team", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "skips, and records the operator as the actor" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 1, :skip_points_fine => 25)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    two     = create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)
    sign_in(author)

    post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).to have_http_status(:found)
    expect(passing.reload.current_level).to eq(two)
    row = PointTransaction.find_by(:game_passing_id => passing.id, :reason => "level_skipped")
    expect(row.created_by_id).to eq(author.id)
  end

  # The operator shares skip_level! and therefore every refusal it makes. The
  # game is live -- set_game_schedule! puts starts_at in the past -- so this
  # is genuinely the cap refusing the request, not ensure_game_is_live doing
  # it for an unrelated reason and the assertions below passing vacuously.
  it "is bound by the same cap as the team" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 0)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)
    sign_in(author)

    post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).to have_http_status(:found)
    expect(passing.reload.current_level).to eq(one)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  it "refuses a signed-out stranger" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 1)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)

    post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).to redirect_to(login_path)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end
end
