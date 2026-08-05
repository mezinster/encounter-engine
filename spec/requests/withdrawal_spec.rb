require "rails_helper"

describe "withdrawal", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => false) }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "removes the game from the public listing" do
    game.update!(:withdrawn_at => Time.now)
    expect(Game.visible).not_to include(game)
    expect(Game.non_drafts).to include(game)  # the raw scope is unchanged
  end

  it "keeps it out of the started and notstarted selectors" do
    # Can't set starts_at to a past timestamp directly: Game's
    # game_starts_in_the_future validation rejects it on save. Set
    # withdrawn_at first (starts_at is still in the future, so that
    # validation passes), then move "now" past the game's starts_at --
    # same technique spec/models/game/started_spec.rb uses -- so #started?
    # reads true for the query below without touching the column.
    game.update!(:withdrawn_at => Time.now)
    allow(Time).to receive(:now).and_return(DateTime.new(2099, 6, 1))
    expect(Game.started).not_to include(game)
    expect(Game.notstarted).not_to include(game)
  end

  # The operator's own view must keep working, or every withdrawal generates a
  # support question from the author asking where their game went.
  it "stays visible to its author and to a superadmin" do
    game.update!(:withdrawn_at => Time.now)
    sign_in(author)
    get game_path(game)
    expect(response).to have_http_status(:ok)

    sign_in(superadmin)
    get game_path(game)
    expect(response).to have_http_status(:ok)
  end

  # A withdrawn game's URL still resolves (it survives in chat logs,
  # bookmarks, invitations) -- the listing being clean is not enough. Review
  # finding: this was previously unguarded, and both an anonymous visitor and
  # a logged-in stranger got 200 with the full page (description, teams).
  it "refuses an anonymous visitor on the show page" do
    game.update!(:withdrawn_at => Time.now)
    get game_path(game)
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a logged-in stranger on the show page" do
    game.update!(:withdrawn_at => Time.now)
    sign_in(create_user)
    get game_path(game)
    expect(response).to have_http_status(:unauthorized)
  end

  # Review finding: GameEntriesController#new was unguarded -- a team could
  # still register for a withdrawn game (GameEntry count 0 -> 1, 302), because
  # Game#can_request? is pre-existing dead code (its capacity check computes
  # a value and discards it, always returning a truthy array) and never
  # enforced anything.
  it "refuses a team requesting entry to a withdrawn game" do
    game.update!(:withdrawn_at => Time.now)
    captain = create_user
    team = create_team(:captain => captain)
    sign_in(captain)

    expect do
      get new_game_entry_path(:game_id => game.id, :team_id => team.id)
    end.not_to change(GameEntry, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it "can be withdrawn and restored by a superadmin" do
    sign_in(superadmin)
    post withdraw_game_path(game)
    expect(game.reload.withdrawn?).to be true
    post restore_game_path(game)
    expect(game.reload.withdrawn?).to be false
  end

  it "cannot be withdrawn by the author" do
    sign_in(author)
    post withdraw_game_path(game)
    expect(game.reload.withdrawn?).to be false
  end
end
