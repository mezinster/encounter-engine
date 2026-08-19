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
  # still register for a withdrawn game (GameEntry count 0 -> 1, 302).
  # Game#can_request? answers a capacity question, not a withdrawal one (see
  # ensure_game_is_not_withdrawn's comment in game_entries_controller.rb), so
  # it would not have caught this even after its own bug was fixed -- this
  # guard has to stand on its own.
  it "refuses a team requesting entry to a withdrawn game" do
    game.update!(:withdrawn_at => Time.now)
    captain = create_user
    team = create_team(:captain => captain)
    sign_in(captain)

    expect do
      post new_game_entry_path(:game_id => game.id, :team_id => team.id)
    end.not_to change(GameEntry, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it "can be withdrawn and restored by a superadmin" do
    sign_in(superadmin)
    post withdraw_game_path(game), :params => { :withdrawal_category => "other",
                                                :withdrawal_mode => "freeze" }
    expect(game.reload.withdrawn?).to be true
    expect(response).to redirect_to(admin_games_path)

    post restore_game_path(game)
    expect(game.reload.withdrawn?).to be false
    expect(response).to redirect_to(admin_games_path)
  end

  it "cannot be withdrawn by the author" do
    sign_in(author)
    post withdraw_game_path(game)
    expect(game.reload.withdrawn?).to be false
  end

  # Finding 2 of the whole-branch review: editing_locked_at existed as a
  # predicate, a count and a filter, but nothing could ever set or clear it --
  # an operator needed psql to lock a game, and an author locked that way had
  # no route out through the UI. lock/unlock mirror withdraw/restore exactly.
  it "can be locked and unlocked by a superadmin" do
    sign_in(superadmin)
    post lock_game_path(game)
    expect(game.reload.editing_locked?).to be true
    expect(response).to redirect_to(admin_games_path)

    post unlock_game_path(game)
    expect(game.reload.editing_locked?).to be false
    expect(response).to redirect_to(admin_games_path)
  end

  it "cannot be locked by the author" do
    sign_in(author)
    post lock_game_path(game)
    expect(game.reload.editing_locked?).to be false
  end

  # An operator withdraws or freezes a game BECAUSE it is running badly, so a
  # started game is the normal case for all four of these -- yet every example
  # above uses create_game, whose starts_at defaults to 2099. That gap shipped:
  # a running game does not pass its own validations (game_starts_in_the_future
  # fires whenever author_finished_at is nil and starts_at is past), so the
  # update! these actions used raised RecordInvalid and the operator got a bare
  # 422. Reported from production on a game that had just entered test mode.
  #
  # Each example asserts the state actually changed AND that the response is a
  # redirect rather than 422 -- the state assertion alone would pass if the
  # action were removed and something else set the column.
  describe "on a game that has already started" do
    let(:live) do
      g = create_game(:author => author, :is_draft => false)
      set_game_schedule!(g, :starts_at => 1.hour.ago)
      g
    end

    before { sign_in(superadmin) }

    it "can still be withdrawn" do
      post withdraw_game_path(live), :params => { :withdrawal_category => "other",
                                                  :withdrawal_mode => "freeze" }

      expect(response).to have_http_status(:found)
      expect(live.reload.withdrawn?).to be true
    end

    it "can still be restored" do
      live.update_column(:withdrawn_at, Time.now)

      post restore_game_path(live)

      expect(response).to have_http_status(:found)
      expect(live.reload.withdrawn?).to be false
    end

    it "can still be locked" do
      post lock_game_path(live)

      expect(response).to have_http_status(:found)
      expect(live.reload.editing_locked?).to be true
    end

    it "can still be unlocked" do
      live.update_column(:editing_locked_at, Time.now)

      post unlock_game_path(live)

      expect(response).to have_http_status(:found)
      expect(live.reload.editing_locked?).to be false
    end

    # The four above would pass on a game whose validations happen to hold.
    # This pins the precondition that makes them meaningful: the record really
    # is invalid, so anything routing these writes back through validations
    # regresses to a 422.
    it "is a game that does not pass its own validations" do
      expect(live.valid?).to be false
      expect(live.errors[:starts_at]).not_to be_empty
    end
  end

  # Finding 5 of the whole-branch review: Spec A's headline guarantee --
  # "teams already mid-race continue uninterrupted" -- had no test pinning it.
  # GamePassingsController#find_game does a bare Game.find (see that
  # method's comment), never Game.visible, so withdrawal must not block an
  # in-flight game_passing. This proves it end to end over HTTP rather than
  # trusting that no future before_action tightens the scope.
  it "lets a team mid-race keep playing a game that is withdrawn under them" do
    now = Time.now
    Time.stub(:now => now - 1)
    started_game = create_game(:author => author, :is_draft => false, :starts_at => now)
    level = create_level(:game => started_game)
    Time.stub(:now => now + 1)

    captain = create_user
    team = create_team(:captain => captain)
    create_game_passing(:level => level, :team => team)

    # update_column, not update!: starts_at is now in the past relative to
    # the stubbed clock, and game_starts_in_the_future re-validates on every
    # save regardless of which attribute changed (see
    # spec/models/game/count_by_status_spec.rb for the same workaround).
    started_game.update_column(:withdrawn_at, Time.now)

    sign_in(captain)
    get show_current_level_path(game_id: started_game.id)

    expect(response).to have_http_status(:ok)
  end

  # Finding 4 of the whole-branch review: GamesController#index is exempt
  # from require_authentication!, and its params[:user_id] branch returned
  # `User.find(params[:user_id]).created_games` completely unscoped --
  # Game.visible guarded only the other (no user_id) branch. GET
  # /games?user_id=N therefore rendered a withdrawn game to any anonymous
  # visitor.
  it "does not leak a withdrawn game through ?user_id= to an anonymous visitor" do
    game.update!(:withdrawn_at => Time.now)

    get games_path(:user_id => author.id)

    expect(response.body).not_to include(game.name)
  end

  it "does not leak a withdrawn game through ?user_id= to a logged-in stranger" do
    game.update!(:withdrawn_at => Time.now)
    sign_in(create_user)

    get games_path(:user_id => author.id)

    expect(response.body).not_to include(game.name)
  end

  it "still shows the author their own withdrawn game through ?user_id=" do
    game.update!(:withdrawn_at => Time.now)
    sign_in(author)

    get games_path(:user_id => author.id)

    expect(response.body).to include(game.name)
  end

  it "still shows a superadmin a withdrawn game through ?user_id=" do
    game.update!(:withdrawn_at => Time.now)
    sign_in(superadmin)

    get games_path(:user_id => author.id)

    expect(response.body).to include(game.name)
  end
end
