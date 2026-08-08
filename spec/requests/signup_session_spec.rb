require "rails_helper"

# SessionsController#create calls reset_session before writing :user_id and
# carries a comment explaining why. Registration performs the identical
# anonymous -> authenticated transition and did not.
#
# The property that matters is the one reset_session actually guarantees:
# whatever was in the session before signup -- here, another user's login --
# is gone afterwards, replaced by a genuinely fresh session, not merely
# overwritten in place. Two things make a naive version of this test
# vacuous, both discovered while writing it, so noted for the next person:
#
# 1. Starting from a signup page GET (no prior session) doesn't exercise
#    anything: CookieStore never issues a session id for an untouched
#    session (nothing was written, so no cookie is even set), so "before"
#    reads as blank and any real id after the POST differs trivially,
#    fixed or not. Starting from a real, already-persisted session (via
#    login, which does write session[:user_id]) closes that gap.
# 2. `session.id` returns a `Rack::Session::SessionId`-wrapping object that
#    is freshly constructed, and memoized, per request -- it is NOT the
#    same object across two separate HTTP calls in the same example, and
#    `Rack::Session::SessionId` never defines `#==`, so comparing the
#    objects directly (`eq`/`not_to eq`) always compares by identity and
#    is therefore always "not equal", regardless of whether the underlying
#    id actually changed. `.to_s` (an explicit delegated method) must be
#    compared instead.
describe "signing up", type: :request do
  it "replaces a pre-existing session rather than merging into it" do
    existing_user = create_user
    put login_path, :params => { :email => existing_user.email, :password => "1234" }
    before_id = session.id.to_s
    expect(session[:user_id]).to eq(existing_user.id)

    new_email = "fresh#{rand(100000)}@example.com"
    post users_path, :params => { :user => { :nickname => "fresh#{rand(100000)}",
                                             :email => new_email,
                                             :password => "1234",
                                             :password_confirmation => "1234" } }
    new_user = User.find_by!(email: new_email)

    expect(response).to redirect_to(dashboard_path)
    expect(session.id.to_s).not_to eq(before_id)
    expect(session[:user_id]).to eq(new_user.id)
  end
end
