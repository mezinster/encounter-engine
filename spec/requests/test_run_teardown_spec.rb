require "rails_helper"

# finish_test is the only thing standing between a test run and the real game.
# Anything it forgets outlives the test.
describe "finishing a test run", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
  end

  it "generates a token when the test starts" do
    game.current_run.test_token.should_not be_nil
  end

  it "clears the token when the test finishes" do
    post finish_test_game_path(game)

    game.reload.current_run.test_token.should be_nil
  end

  it "deletes the run's admissions" do
    create_test_admission(:run => game.current_run, :team => create_team)

    expect {
      post finish_test_game_path(game)
    }.to change { TestAdmission.count }.by(-1)
  end

  it "destroys a disposable team once its passing is gone" do
    tester = create_user
    team   = create_team
    create_test_admission(:run => game.current_run, :team => team, :user => tester)
    GamePassing.create!(:team => team, :game => game,
                        :game_run => game.current_run, :current_level => level)

    expect {
      post finish_test_game_path(game)
    }.to change { Team.exists?(team.id) }.from(true).to(false)
  end

  # The order in the sweep is load-bearing: Team#deletable? refuses any team
  # holding a passing OR a log line, so consulting it before those are deleted
  # spares every disposable team. An unplayed test passes either way -- this is
  # the case that catches a wrong order.
  it "destroys a disposable team whose tester actually played" do
    tester = create_user
    team   = create_team
    create_test_admission(:run => game.current_run, :team => team, :user => tester)
    GamePassing.create!(:team => team, :game => game,
                        :game_run => game.current_run, :current_level => level)
    Log.create!(:game_id => game.id, :game_run_id => game.current_run.id,
                :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "x")

    post finish_test_game_path(game)

    Team.exists?(team.id).should be false
  end

  # The deletable? guard, not the happy path.
  it "never destroys a real team that was admitted" do
    captain = create_user
    real    = create_team(:captain => captain)
    create_test_admission(:run => game.current_run, :team => real)

    post finish_test_game_path(game)

    Team.exists?(real.id).should be true
  end
end
