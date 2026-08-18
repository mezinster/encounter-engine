require "rails_helper"

describe "playing a gated game", type: :request do
  let(:level)  { create_level }
  let(:game)   { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }
  let(:captain) { create_user }
  let(:team)   { create_team(:captain => captain) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses a team with no pass" do
    team
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
    expect(GamePassing.where(:team_id => team.id)).to be_empty
  end

  it "creates a runless attempt bound to the pass" do
    pass = create_access_pass(:game => game, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    attempt = GamePassing.find_by(:team_id => team.id)
    expect(attempt.game_run_id).to be_nil
    expect(attempt.access_pass_id).to eq(pass.id)
    expect(attempt.current_level_id).to eq(level.id)
  end

  it "serves the same attempt on a second visit rather than making another" do
    create_access_pass(:game => game, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)
    expect { get show_current_level_path(:game_id => game.id) }
      .not_to change { GamePassing.count }
  end

  it "consumes the second pass after the first attempt is completed" do
    first = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    GamePassing.find_by(:access_pass_id => first.id).update!(:finished_at => Time.now)

    second = create_access_pass(:game => game, :team => team)
    get show_current_level_path(:game_id => game.id)

    expect(GamePassing.where(:team_id => team.id).count).to eq(2)
    expect(GamePassing.find_by(:access_pass_id => second.id)).to be_present
  end

  it "refuses a team whose only pass was spent by quitting" do
    pass = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    GamePassing.find_by(:access_pass_id => pass.id).exit!

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
  end

  it "lets a team that quit start again on a replacement pass" do
    first = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    GamePassing.find_by(:access_pass_id => first.id).exit!

    create_access_pass(:game => game, :team => team)
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(GamePassing.where(:team_id => team.id).count).to eq(2)
  end

  it "refuses a gated game that is still a draft" do
    game.update!(:visibility => "draft")
    create_access_pass(:game => game.reload, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not require a start date" do
    create_access_pass(:game => game, :team => team)
    game.current_run.update_column(:starts_at, nil)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
  end
end
