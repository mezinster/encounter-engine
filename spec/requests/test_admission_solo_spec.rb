require "rails_helper"

describe "admitting a solo player to a test run", type: :request do
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

  it "admits a player by nickname" do
    tester = create_user

    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }
    }.to change { TestAdmission.count }.by(1)

    TestAdmission.last.user_id.should == tester.id
  end

  it "creates exactly one disposable team" do
    tester = create_user

    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }
    }.to change { Team.count }.by(1)
  end

  it "refuses to admit the author, who is already exempt" do
    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => author.nickname }
    }.not_to change { TestAdmission.count }

    follow_redirect!
    response.body.should include("Автор уже может тестировать свою игру")
  end

  it "reports an unknown nickname" do
    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => "нетушки" }
    }.not_to change { TestAdmission.count }

    follow_redirect!
    response.body.should include("Игрок «нетушки» не найден")
  end

  it "is idempotent" do
    tester = create_user
    post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }

    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }
    }.not_to change { TestAdmission.count }
  end
end
