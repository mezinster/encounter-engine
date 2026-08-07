require "rails_helper"

# GameEntriesController takes its target team from the URL -- params[:team_id]
# on #new, and the entry's own team everywhere else -- but guarded those actions
# with SecurityFilters#ensure_team_captain, which only asks "is this user *a*
# captain", never "captain of THIS team".
#
# Same shape as the cross-tenant hole fixed in the level/question/answer/option/
# hint controllers: an authorization check on one record paired with an unscoped
# lookup of another.
describe "acting on another team's game entry", type: :request do
  let(:author)     { create_user }
  let(:game)       { create_game(:author => author, :max_team_number => 5, :is_draft => false) }

  let(:victim)     { u = create_user; create_team(:captain => u); u.reload }
  let(:attacker)   { u = create_user; create_team(:captain => u); u.reload }

  let(:victim_entry) do
    GameEntry.create!(:game => game, :team => victim.team, :status => "new")
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    expect(attacker.captain?).to be true
    expect(victim.captain?).to be true
    expect(attacker.team_id).not_to eq(victim.team_id)
  end

  # recall / cancel / reopen all resolve @entry with an unscoped
  # GameEntry.find(params[:id]).
  describe "a captain of a different team" do
    it "cannot recall it" do
      victim_entry
      sign_in(attacker)

      post "/game_entries/recall/#{victim_entry.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(victim_entry.reload.status).to eq("new")
    end

    it "cannot cancel it" do
      victim_entry.accept!
      sign_in(attacker)

      post "/game_entries/cancel/#{victim_entry.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(victim_entry.reload.status).to eq("accepted")
    end

    it "cannot reopen it" do
      victim_entry.reject!
      sign_in(attacker)

      post "/game_entries/reopen/#{victim_entry.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(victim_entry.reload.status).to eq("rejected")
    end

    # The second hole, and the more damaging one: #new resolves the team from
    # params[:team_id] with an unscoped Team.find, so a captain could register
    # somebody else's team for a game -- and reserve_place_for_team! would
    # consume one of that game's limited slots on their behalf.
    it "cannot register that team for a game" do
      sign_in(attacker)

      expect {
        post new_game_entry_path(:game_id => game.id, :team_id => victim.team_id)
      }.not_to change { GameEntry.where(:team_id => victim.team_id).count }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # The guard must not break the ordinary case it exists to permit.
  describe "a captain acting on their own team" do
    it "can recall their own entry" do
      own = GameEntry.create!(:game => game, :team => attacker.team, :status => "new")
      sign_in(attacker)

      post "/game_entries/recall/#{own.id}"

      expect(response).to redirect_to(dashboard_path)
      expect(own.reload.status).to eq("recalled")
    end

    it "can register their own team" do
      sign_in(attacker)

      expect {
        post new_game_entry_path(:game_id => game.id, :team_id => attacker.team_id)
      }.to change { GameEntry.where(:team_id => attacker.team_id).count }.by(1)

      expect(response).to redirect_to(dashboard_path)
    end
  end

  # accept/reject are the author's actions, gated by ensure_author rather than
  # by captaincy. Pinned so the new filter cannot be widened over them by
  # accident.
  describe "the game's author" do
    it "can still accept an entry without being any team's captain" do
      victim_entry
      sign_in(author)

      post "/game_entries/accept/#{victim_entry.id}"

      expect(response).to redirect_to(dashboard_path)
      expect(victim_entry.reload.status).to eq("accepted")
    end
  end
end
