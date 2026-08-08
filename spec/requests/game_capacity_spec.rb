require "rails_helper"

describe "the team cap", type: :request do
  let(:author)  { create_user }
  let(:game)    { create_game(:author => author, :max_team_number => 1, :is_draft => false) }
  let(:captain) { u = create_user; create_team(:captain => u); u.reload }

  before do
    game.update_column(:requested_teams_number, 1)  # the cap is already reached
    put login_path, :params => { :email => captain.email, :password => "1234" }
  end

  # The view hides the link, so this is only reachable by requesting the URL
  # directly -- which is exactly the case a server-side check exists for.
  it "refuses a registration once the cap is reached" do
    expect {
      post new_game_entry_path(:game_id => game.id, :team_id => captain.team_id)
    }.not_to change { GameEntry.count }
  end

  it "still allows a registration below the cap" do
    game.update_column(:requested_teams_number, 0)

    expect {
      post new_game_entry_path(:game_id => game.id, :team_id => captain.team_id)
    }.to change { GameEntry.count }.by(1)
  end

  describe "#can_request?" do
    it "is false at the cap" do
      expect(game.can_request?).to be false
    end

    it "is true below the cap" do
      game.update_column(:requested_teams_number, 0)

      expect(game.reload.can_request?).to be true
    end
  end
end
