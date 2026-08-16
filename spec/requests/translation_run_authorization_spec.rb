require "rails_helper"

describe "translation run authorization", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before { allow(Translation::Client).to receive(:configured?).and_return(true) }

  # Deliberately require_superadmin!, NOT ensure_author. ensure_author is a
  # marked security chokepoint that already admits superadmins to author
  # actions; this feature spends real money against a shared API key, so the
  # author of a game must not reach it.
  #
  # Status is :unauthorized (401), not 403: ApplicationController's
  # deny_unauthorized renders status: :unauthorized for every
  # Authentication::Unauthorized this app raises (see
  # spec/requests/superadmin_authorization_spec.rb, "refuses a stranger"), and
  # require_superadmin! raises exactly that. Asserting 403 here would diverge
  # from every other superadmin-gated action in the app for no reason specific
  # to this controller.
  it "refuses the game's own author" do
    sign_in(author)

    post game_translation_runs_path(game), :params => { :locales => [ "en" ] }
    expect(response).to have_http_status(:unauthorized)

    get new_game_translation_run_path(game)
    expect(response).to have_http_status(:unauthorized)
  end

  # A guest is refused earlier and differently, same as every other
  # authenticated-only action: require_authentication! runs before
  # require_superadmin!, raises Authentication::Unauthenticated, and
  # deny_unauthenticated redirects to the login form (302), not a 401/403 --
  # see superadmin_authorization_spec.rb's "still refuses an anonymous
  # visitor" for the same pattern on ensure_author.
  it "refuses a guest" do
    post game_translation_runs_path(game), :params => { :locales => [ "en" ] }
    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(login_path)
  end

  it "admits a superadmin" do
    sign_in(superadmin)
    get new_game_translation_run_path(game)

    expect(response.status).to eq(200)
  end

  # With no key the feature does not exist at all -- development and CI need
  # no credential. require_api_key! raises the same Authentication::Unauthorized
  # as require_superadmin!, so the status matches (401, not 403).
  it "refuses everyone when no API key is configured" do
    allow(Translation::Client).to receive(:configured?).and_return(false)
    sign_in(superadmin)

    post game_translation_runs_path(game), :params => { :locales => [ "en" ] }
    expect(response).to have_http_status(:unauthorized)
  end
end
