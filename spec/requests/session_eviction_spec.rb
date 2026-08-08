require "rails_helper"

# CookieStore has no server-side session record, so a stolen cookie stays valid
# forever unless the session is bound to something that changes with the
# credential.
describe "session eviction on password change", type: :request do
  let(:user) { create_user }

  it "stops accepting a session issued before the password changed" do
    put login_path, :params => { :email => user.email, :password => "1234" }
    stolen = session[:session_token]
    expect(stolen).to be_present

    user.update!(:password => "rotated", :password_confirmation => "rotated")

    expect(user.reload.session_token).not_to eq(stolen)
  end

  # This is the property the whole task exists to create. The other two
  # examples check that the model rotates and that the changing browser
  # survives its own action -- neither replays the old cookie against a
  # protected endpoint, so neither would fail if current_user stopped
  # checking session_token at all. Mutation-tested: reverting current_user to
  # `session[:user_id] && User.find_by(id: session[:user_id])` (the
  # pre-task, vulnerable version) makes this example fail while leaving the
  # rest of the suite green -- see task-3-report.md.
  it "rejects a cookie that predates a password change made out-of-band" do
    put login_path, :params => { :email => user.email, :password => "1234" }
    get dashboard_path
    expect(response).to have_http_status(:ok)

    # Out-of-band: this browser's cookie is untouched by the change -- e.g.
    # the password was changed from another device, or by an admin. Nothing
    # in this example resets the integration session's cookie jar, so the
    # next request below replays the exact cookie issued at login, before
    # the rotation.
    user.update!(:password => "rotated", :password_confirmation => "rotated")

    get dashboard_path
    expect(response).to redirect_to(login_path)
  end

  it "keeps the changing browser signed in" do
    put login_path, :params => { :email => user.email, :password => "1234" }

    patch user_path(user), :params => { :user => { :current_password => "1234",
                                                   :password => "rotated",
                                                   :password_confirmation => "rotated" } }

    get dashboard_path
    expect(response).to have_http_status(:ok)
  end
end
