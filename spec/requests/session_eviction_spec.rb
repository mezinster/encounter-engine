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

  it "keeps the changing browser signed in" do
    put login_path, :params => { :email => user.email, :password => "1234" }

    patch user_path(user), :params => { :user => { :current_password => "1234",
                                                   :password => "rotated",
                                                   :password_confirmation => "rotated" } }

    get dashboard_path
    expect(response).to have_http_status(:ok)
  end
end
