require "rails_helper"

# may_start_passing?'s is_testing? exemption is scoped to the author's own team
# on purpose: widening it would let any authenticated user read every level and
# answer code of an unpublished game. An admission is the narrow widening.
describe "playing a test run you were admitted to", type: :request do
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
    delete logout_path
  end

  it "refuses an authenticated stranger with no admission" do
    stranger = create_user
    stranger.update!(:team => create_team(:captain => stranger))
    sign_in(stranger)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:unauthorized)
  end

  it "lets an admitted real team play" do
    captain = create_user
    team    = create_team(:captain => captain)
    captain.update!(:team => team)
    create_test_admission(:run => game.reload.current_run, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
  end

  it "lets a teamless solo tester play through their disposable team" do
    tester = create_user
    team   = create_team
    create_test_admission(:run => game.reload.current_run, :team => team,
                          :user => tester)
    sign_in(tester)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
    GamePassing.where(:game_run_id => game.reload.current_run.id,
                      :team_id => team.id).count.should == 1
  end

  # The entire design in one assertion.
  it "never writes users.team_id for a solo tester who already has a team" do
    tester = create_user
    real   = create_team(:captain => tester)
    tester.update!(:team => real)
    disposable = create_team
    create_test_admission(:run => game.reload.current_run, :team => disposable,
                          :user => tester)
    sign_in(tester)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
    tester.reload.team_id.should == real.id
    real.reload.captain_id.should == tester.id
    GamePassing.where(:team_id => disposable.id).count.should == 1
    GamePassing.where(:team_id => real.id).count.should == 0
  end

  # ensure_team_member reads users.team_id -- the one column this design never
  # writes -- so without an exemption it 401s the tester after everything else
  # has worked.
  it "does not require real team membership of a solo tester" do
    tester = create_user
    tester.team_id.should be_nil
    create_test_admission(:run => game.reload.current_run,
                          :team => create_team, :user => tester)
    sign_in(tester)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
  end

  it "still requires real team membership outside a test run" do
    stranger = create_user
    sign_in(stranger)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:unauthorized)
  end
end
