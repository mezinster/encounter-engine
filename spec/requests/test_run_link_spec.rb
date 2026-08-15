require "rails_helper"

describe "joining a test run by link", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def token
    game.reload.current_run.test_token
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
    delete logout_path
  end

  # The GET is a confirmation page, not a grant: this URL is meant to be pasted
  # into a chat, where a link-preview bot following it would otherwise admit
  # whatever account it holds.
  it "admits nobody on GET" do
    sign_in(create_user)

    expect {
      get test_invite_path(:game_id => game.id, :token => token)
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:ok)
  end

  it "admits on POST" do
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => token)
    }.to change { TestAdmission.count }.by(1)

    TestAdmission.last.solo?.should be true
  end

  it "refuses a wrong token" do
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => "wrong-token-entirely")
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "requires authentication" do
    post join_test_path(:game_id => game.id, :token => token)

    TestAdmission.count.should == 0
    response.should_not have_http_status(:ok)
  end

  it "is dead after the test finishes" do
    stale = token
    sign_in(author)
    post finish_test_game_path(game)
    delete logout_path
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => stale)
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "is dead after the author resets it" do
    stale = token
    sign_in(author)
    post reset_test_token_path(:game_id => game.id)
    game.reload.current_run.test_token.should_not == stale

    delete logout_path
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => stale)
    }.not_to change { TestAdmission.count }
  end

  it "does not admit the author twice" do
    sign_in(author)

    expect {
      post join_test_path(:game_id => game.id, :token => token)
    }.not_to change { TestAdmission.count }
  end

  it "is idempotent for someone already admitted" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)
    sign_in(tester)

    expect {
      post join_test_path(:game_id => game.id, :token => token)
    }.not_to change { TestAdmission.count }
  end
end
