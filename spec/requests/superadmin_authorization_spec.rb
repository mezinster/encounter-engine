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
    expect(response).not_to have_http_status(:ok)
  end

  it "lets a superadmin edit someone else's game" do
    sign_in(superadmin)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end

  it "still refuses an anonymous visitor" do
    get edit_game_path(game)
    expect(response).not_to have_http_status(:ok)
  end

  it "stops the author editing a locked game" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(author)
    get edit_game_path(game)
    expect(response).not_to have_http_status(:ok)
  end

  it "still lets a superadmin edit a locked game" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(superadmin)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end
end
