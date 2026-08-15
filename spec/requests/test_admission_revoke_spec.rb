require "rails_helper"

# find_or_create_game_passing returns early the moment a passing exists, so
# may_start_passing? is consulted ONLY when there is none. A revoke that leaves
# the passing behind changes nothing at all -- the tester keeps playing while
# the panel shows them removed.
describe "revoking a test admission", type: :request do
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

  it "deletes the admission" do
    admission = create_test_admission(:run => game.current_run, :team => create_team)

    expect {
      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)
    }.to change { TestAdmission.count }.by(-1)
  end

  it "deletes the tester's passing in this run" do
    tester    = create_user
    team      = create_team
    admission = create_test_admission(:run => game.current_run, :team => team, :user => tester)
    GamePassing.create!(:team => team, :game => game,
                        :game_run => game.current_run, :current_level => level)

    expect {
      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)
    }.to change { GamePassing.where(:team_id => team.id).count }.from(1).to(0)
  end

  it "actually stops the tester from playing" do
    tester    = create_user
    team      = create_team
    admission = create_test_admission(:run => game.current_run, :team => team, :user => tester)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)
    response.should have_http_status(:ok)

    delete logout_path
    sign_in(author)
    post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)
    response.should have_http_status(:unauthorized)
  end

  it "destroys the disposable team" do
    tester    = create_user
    team      = create_team
    admission = create_test_admission(:run => game.current_run, :team => team, :user => tester)

    post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

    Team.exists?(team.id).should be false
  end

  it "leaves a real team alone" do
    real      = create_team(:captain => create_user)
    admission = create_test_admission(:run => game.current_run, :team => real)

    post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

    Team.exists?(real.id).should be true
  end

  it "refuses a stranger" do
    admission = create_test_admission(:run => game.current_run, :team => create_team)
    delete logout_path
    sign_in(create_user)

    expect {
      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  # An unscoped find paired with an authorization check that never names the
  # record is the shape of the cross-tenant hole fixed in the level, question,
  # answer, option and hint controllers.
  it "refuses an admission belonging to another game" do
    other = create_game(:author => author, :is_draft => true)
    create_level(:game => other)
    other.current_run.update_column(:is_testing, true)
    foreign = create_test_admission(:run => other.current_run, :team => create_team)

    # Asserted as a raise rather than a 404 response, matching the convention
    # in spec/requests/level_authorization_spec.rb and five other files: this
    # app installs no rescue_from for RecordNotFound, so a request spec sees
    # the exception itself.
    expect {
      expect {
        post revoke_test_admission_path(:game_id => game.id, :id => foreign.id)
      }.to raise_error(ActiveRecord::RecordNotFound)
    }.not_to change { TestAdmission.count }
  end
end
