require "rails_helper"

describe "superadmin authorization", type: :request do
  let(:author)     { create_user }
  let(:stranger)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#create (the actual login). It is PUT, not POST.
  # create_user (spec/spec_helpers/fixtures_helper.rb) sets password "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "lets the author edit their own game" do
    sign_in(author)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end

  # The bug class this codebase has actually shipped: a destructive action
  # reachable by someone who is neither the author nor an operator.
  it "refuses a stranger" do
    sign_in(stranger)
    get edit_game_path(game)
    expect(response).to have_http_status(:unauthorized)
  end

  it "lets a superadmin edit someone else's game" do
    sign_in(superadmin)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end

  # A signed-out visitor is refused earlier and differently: require_authentication!
  # runs before ensure_author, raises Unauthenticated, and deny_unauthenticated
  # redirects to the login form. Still a refusal -- nothing renders -- but a 302
  # rather than the 401 a signed-in non-author gets. Asserting the redirect
  # target rather than "not 200" keeps a future 500 from passing as a refusal.
  it "still refuses an anonymous visitor" do
    get edit_game_path(game)
    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(login_path)
  end

  it "stops the author editing a locked game" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(author)
    get edit_game_path(game)
    expect(response).to have_http_status(:unauthorized)
  end

  it "still lets a superadmin edit a locked game" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(superadmin)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end

  # The editing lock covers content and settings, not read-only views. This is
  # the regression the ensure_editing_not_locked split (as opposed to putting
  # the check in ensure_author) exists to prevent: an author under
  # investigation must still be able to watch their own game's live log.
  it "still lets the author view their own game's live log when the game is locked" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(author)
    get show_live_channel_path(game)
    expect(response).to have_http_status(:ok)
  end

  # Finding 1 of the whole-branch review: finish_test (GamesController#finish_test)
  # unconditionally deletes every game_passing and log line for the game. That
  # was guarded only by ensure_author, not by the lock -- so a locked author
  # could erase the very evidence an operator locked the game to investigate,
  # which makes Game#deletable? true and opens a path to deleting the game
  # outright. Both new invariants (frozen content, frozen lifecycle) fell to
  # one request -- unprotected by CSRF too, back when this route was still
  # GET; it is POST now (see config/routes.rb), but the authorization gap
  # this spec pins was never about the verb.
  it "stops a locked author erasing history and passings through finish_test" do
    game.update!(:editing_locked_at => Time.now)
    passing = create_game_passing(:level => create_level(:game => game))
    sign_in(author)

    expect do
      post finish_test_game_path(game)
    end.not_to change(GamePassing, :count)

    expect(response).to have_http_status(:unauthorized)
    expect(GamePassing.exists?(passing.id)).to be true
    expect(game.reload.deletable?).to be false
  end

  it "still lets a superadmin reach finish_test on a locked game" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(superadmin)

    post finish_test_game_path(game)

    expect(response).to redirect_to(game_path(game))
  end
end
