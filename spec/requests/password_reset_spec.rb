require "rails_helper"

describe "password reset", type: :request do
  let(:user) { create_user }

  def request_reset_for(email)
    post password_resets_path, :params => { :email => email }
  end

  def token_from_last_mail
    ActionMailer::Base.deliveries.last.body.to_s[%r{/password/edit\?token=([A-Za-z0-9_-]+)}, 1]
  end

  before { ActionMailer::Base.deliveries.clear }

  it "mails a working token" do
    request_reset_for(user.email)

    token = token_from_last_mail
    expect(token).to be_present

    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "brandnew",
                                                       :password_confirmation => "brandnew" } }

    expect(user.reload.authenticate("brandnew")).to be true
  end

  it "does not reveal whether an address is registered" do
    request_reset_for(user.email)
    known = response.body

    request_reset_for("nobody#{rand(100000)}@example.com")

    expect(response.body).to eq(known)
    expect(ActionMailer::Base.deliveries.length).to eq(1)
  end

  it "refuses an expired token" do
    request_reset_for(user.email)
    token = token_from_last_mail
    user.update_column(:reset_password_sent_at, 3.hours.ago)

    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "brandnew",
                                                       :password_confirmation => "brandnew" } }

    expect(user.reload.authenticate("brandnew")).to be false
  end

  it "refuses a token twice" do
    request_reset_for(user.email)
    token = token_from_last_mail

    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "first",
                                                       :password_confirmation => "first" } }
    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "second",
                                                       :password_confirmation => "second" } }

    expect(user.reload.authenticate("first")).to be true
    expect(user.authenticate("second")).to be false
  end

  it "evicts another logged-in session when the reset sets a different password" do
    # A completed reset is supposed to rotate session_token "for free" via
    # User#rotate_session_token (see AddSessionTokenToUsers) -- proving that
    # end to end here, not just inferring it from the callback wiring, since
    # a reset flow that quietly fails to evict a stolen session is exactly
    # the kind of thing a unit-level test of the model callback alone would
    # miss. open_session gives this example a second, independent cookie jar
    # standing in for "someone else's browser, or an attacker's".
    other_browser = open_session
    other_browser.post login_path, :params => { :email => user.email, :password => "1234" }
    other_browser.get dashboard_path
    expect(other_browser.response).to have_http_status(:ok)

    request_reset_for(user.email)
    token = token_from_last_mail
    patch password_reset_path, :params => { :token => token,
                                            :user => { :password => "brandnew",
                                                       :password_confirmation => "brandnew" } }

    other_browser.get dashboard_path
    expect(other_browser.response).to redirect_to(login_path)
  end
end
