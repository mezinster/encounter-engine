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

  # The ledger goes with the run. "Append-only" means the ledger is never
  # REVERSED -- no compensating entry, no edit -- not that a row outlives the
  # run it describes, and this action erases the run.
  it "deletes the run's ledger rows" do
    team = create_team(:captain => create_user)
    passing = GamePassing.create!(:team => team, :game => game,
                                  :game_run => game.current_run,
                                  :current_level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)

    expect {
      post finish_test_game_path(game)
    }.to change { PointTransaction.count }.by(-1)
  end

  it "leaves no ledger row pointing at a passing it deleted" do
    team = create_team(:captain => create_user)
    passing = GamePassing.create!(:team => team, :game => game,
                                  :game_run => game.current_run,
                                  :current_level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)

    post finish_test_game_path(game)

    orphans = PointTransaction.where.not(
      :game_passing_id => GamePassing.select(:id)
    )
    expect(orphans).to be_empty
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

# The reachable path the whole-branch review found (F3): start_test does not
# refuse a game that is already running, so a REAL run -- with real passings
# and a real ledger behind it -- can be flipped into testing and then swept.
# Before the fix that left the rows orphaned and the game permanently
# undeletable, with no UI able to reach either.
describe "finishing a test run that was started on a live game", type: :request do
  let(:author) { create_user }
  let(:game) do
    create_game(:author => author, :points_enabled => true,
                :level_completion_points => 10, :game_completion_points => 50)
  end
  let!(:level) { create_level(:game => game, :position => 1) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    set_game_schedule!(game, :starts_at => Time.now - 1.hour)
    game.reload
  end

  it "takes the real run's ledger rows with it and leaves the game deletable" do
    team    = create_team(:captain => create_user)
    passing = GamePassing.create!(:team => team, :game => game,
                                  :game_run => game.current_run,
                                  :current_level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => passing, :reason => "game_completed",
                            :amount => 50)
    expect(PointTransaction.count).to eq(2)

    sign_in(author)
    post start_test_game_path(game)
    expect(game.reload.current_run.is_testing).to be true
    post finish_test_game_path(game)

    expect(GamePassing.where(:game_id => game.id)).to be_empty
    expect(PointTransaction.where(:game_id => game.id)).to be_empty
    expect(game.reload.deletable?).to be true
  end
end
