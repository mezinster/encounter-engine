require "rails_helper"

describe "the team cap", type: :request do
  let(:author)  { create_user }
  let(:game)    { create_game(:author => author, :max_team_number => 1, :is_draft => false) }
  let(:captain) { u = create_user; create_team(:captain => u); u.reload }

  before do
    set_game_schedule!(game, :requested_teams_number => 1)  # the cap is already reached
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
    set_game_schedule!(game, :requested_teams_number => 0)

    expect {
      post new_game_entry_path(:game_id => game.id, :team_id => captain.team_id)
    }.to change { GameEntry.count }.by(1)
  end

  describe "#can_request?" do
    it "is false at the cap" do
      expect(game.can_request?).to be false
    end

    it "is true below the cap" do
      set_game_schedule!(game, :requested_teams_number => 0)

      expect(game.reload.can_request?).to be true
    end
  end

  # GameEntriesController's status transitions are guarded ("only recall! a
  # 'new' entry"), but the counter operations that ride along with them used
  # to be unconditional -- so a double-click on "Отозвать" (recall) called
  # free_place_of_team! twice even though the second recall! was a no-op.
  # Game#free_place_of_team! itself floors at zero, so this only shows up
  # when OTHER active entries keep the counter above zero after the first
  # recall -- exactly reproduced below with a second, unrelated "new" entry.
  describe "recalling the same entry twice" do
    it "does not decrement the counter a second time" do
      game.update!(:max_team_number => 5)
      entry = GameEntry.create!(:game => game, :team => captain.team, :status => "new")

      other_captain = (u = create_user; create_team(:captain => u); u)
      GameEntry.create!(:game => game, :team => other_captain.team, :status => "new")
      set_game_schedule!(game, :requested_teams_number => 2)

      post recall_game_entry_path(entry)
      expect(game.reload.requested_teams_number).to eq(1)

      post recall_game_entry_path(entry) # already "recalled" -- should be a no-op
      expect(game.reload.requested_teams_number).to eq(1)
    end
  end

  # reopen incremented requested_teams_number unconditionally inside the
  # `if @game.can_request?` block, even when reopen! itself was skipped
  # because the entry was already "accepted" -- silently inflating the
  # counter above the number of actually-active entries.
  describe "reopening an already-accepted entry" do
    it "does not inflate the counter" do
      game.update!(:max_team_number => 5)
      entry = GameEntry.create!(:game => game, :team => captain.team, :status => "accepted")
      set_game_schedule!(game, :requested_teams_number => 1)

      post reopen_game_entry_path(entry)

      expect(entry.reload.status).to eq("accepted")
      expect(game.reload.requested_teams_number).to eq(1)
    end
  end
end
