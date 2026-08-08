require "rails_helper"

# Registration used to be enforced only in the view layer -- shared/
# _current_games_status.html.erb hides the "Играть!" link unless the entry is
# accepted, but nothing stopped a direct GET. Any user could create a team and
# play any started game, including one whose entry the author had rejected.
describe "playing a game your team is not registered for", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.update_column(:starts_at, 1.hour.ago)
    g
  end
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Self-service: POST /teams needs only a name, and the creator becomes
  # captain. This is the attacker's entire setup cost.
  def player_on_a_fresh_team
    user = create_user
    team = create_team(:captain => user)
    user.update!(:team => team)
    user
  end

  it "refuses a team that never applied" do
    sign_in(player_on_a_fresh_team)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a team whose entry was rejected" do
    player = player_on_a_fresh_team
    create_game_entry(:game => game, :team => player.team, :status => "rejected")
    sign_in(player)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:unauthorized)
  end

  it "admits a team whose entry was accepted" do
    player = player_on_a_fresh_team
    create_game_entry(:game => game, :team => player.team)
    sign_in(player)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.to change { GamePassing.count }.by(1)

    expect(response).to have_http_status(:ok)
  end

  # GameEntry.of used to return the lowest-id row unconditionally. Nothing
  # stops a team from holding two entries for one game (no unique index, and
  # GameEntriesController#new creates a fresh row on every hit) -- so a team
  # that applied twice, got the first (lower id) rejected and the second
  # (higher id) accepted, was hard-401'd out of a game it was legitimately
  # admitted to.
  it "admits a team whose earlier entry was rejected and later entry accepted" do
    player = player_on_a_fresh_team
    create_game_entry(:game => game, :team => player.team, :status => "rejected")
    create_game_entry(:game => game, :team => player.team, :status => "accepted")
    sign_in(player)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.to change { GamePassing.count }.by(1)

    expect(response).to have_http_status(:ok)
  end

  # find_or_create_game_passing used to run before ensure_game_is_started, so
  # an accepted team GETting /play/:game_id before starts_at got its
  # GamePassing created -- and current_level_entered_at stamped -- before the
  # 401 fired. Nothing restamps that clock at the real start, so the early
  # loader's level-1 hints all read as already elapsed once the game goes
  # live, while honest teams wait. The passing must not exist at all until
  # the game has actually started.
  it "creates no passing when an accepted team plays before the game starts" do
    early_game = create_game(:author => author, :is_draft => false)
    early_game.update_column(:starts_at, 1.hour.from_now)
    create_level(:game => early_game)

    player = player_on_a_fresh_team
    create_game_entry(:game => early_game, :team => player.team)
    sign_in(player)

    expect {
      get show_current_level_path(:game_id => early_game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:unauthorized)
  end

  # The orphan-row defect: find_or_create_game_passing ran at filter position 4
  # while ensure_team_member ran at position 8, so a team-less user's 401 still
  # left a GamePassing with team_id NULL. game_passings/index.html.erb:65 and
  # show_results.html.erb:61 both dereference game_passing.team.name, so that
  # row 500'd the author's stats page and -- after end_game -- the public
  # results page, permanently and with no UI able to remove it.
  it "creates nothing for a user who is on no team" do
    sign_in(create_user)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:unauthorized)
  end

  # A team already mid-game must not be locked out if their entry changes
  # underneath them -- the gate is on starting, not on continuing.
  it "keeps serving a passing that already exists" do
    passing = create_game_passing(:level => level)
    player  = create_user
    player.update!(:team => passing.team)
    passing.team.update!(:captain => player)
    sign_in(player)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
  end

  # The is_testing? exemption in may_start_passing? must be scoped to the
  # author's own team. It is not enough for the game to be in test mode --
  # ensure_game_is_started and ensure_not_author_of_the_game both also return
  # early on is_testing?, so an unscoped exemption would let ANY authenticated
  # user self-register a team and read every level and answer code of an
  # unstarted, unregistered game before it goes live. Previously pinned only
  # by features/games/test-game-1.feature and test-game-2.feature, which
  # never exercise a non-author team in test mode -- nothing in RSpec would
  # have caught a regression here.
  describe "test mode" do
    before do
      game.update_column(:is_testing, true)
    end

    it "admits the author's own team with no entry" do
      team = create_team(:captain => author)
      author.update!(:team => team)
      sign_in(author)

      expect {
        get show_current_level_path(:game_id => game.id)
      }.to change { GamePassing.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    it "refuses a non-author team with no entry" do
      sign_in(player_on_a_fresh_team)

      expect {
        get show_current_level_path(:game_id => game.id)
      }.not_to change { GamePassing.count }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
