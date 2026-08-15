require "rails_helper"

describe "admitting a team to a test run by name", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }
  let!(:level)     { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
    delete logout_path
  end

  it "admits a team the author names" do
    team = create_team(:captain => create_user)
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.to change { TestAdmission.count }.by(1)

    admission = TestAdmission.last
    admission.team_id.should == team.id
    admission.user_id.should be_nil
  end

  it "consumes no registration slot" do
    team = create_team(:captain => create_user)
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { game.reload.current_run.requested_teams_number }
  end

  it "lets a superadmin admit a team to somebody else's game" do
    team = create_team(:captain => create_user)
    sign_in(superadmin)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.to change { TestAdmission.count }.by(1)
  end

  it "records an audit entry for an operator" do
    team = create_team(:captain => create_user)
    sign_in(superadmin)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.to change { AdminAction.count }.by(1)
  end

  it "refuses a stranger" do
    team     = create_team(:captain => create_user)
    stranger = create_user
    sign_in(stranger)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "refuses when the game is not in test mode" do
    sign_in(author)
    post finish_test_game_path(game)
    team = create_team(:captain => create_user)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "reports an unknown team name without creating anything" do
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => "Нет такой" }
    }.not_to change { TestAdmission.count }

    follow_redirect!
    response.body.should include("Команда «Нет такой» не найдена")
  end

  it "is idempotent for an already-admitted team" do
    team = create_team(:captain => create_user)
    create_test_admission(:run => game.current_run, :team => team)
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { TestAdmission.count }
  end
end
