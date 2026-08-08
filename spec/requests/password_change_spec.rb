require "rails_helper"

describe "changing a password", type: :request do
  let(:user) { create_user }

  before do
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses without the current password" do
    patch user_path(user), :params => { :user => { :password => "hijacked",
                                                   :password_confirmation => "hijacked" } }

    expect(user.reload.authenticate("1234")).to be true
    expect(user.authenticate("hijacked")).to be false
  end

  it "refuses with the wrong current password" do
    patch user_path(user), :params => { :user => { :current_password => "wrong",
                                                   :password => "hijacked",
                                                   :password_confirmation => "hijacked" } }

    expect(user.reload.authenticate("1234")).to be true
  end

  it "accepts with the correct current password" do
    patch user_path(user), :params => { :user => { :current_password => "1234",
                                                   :password => "newpass",
                                                   :password_confirmation => "newpass" } }

    expect(user.reload.authenticate("newpass")).to be true
  end

  # A profile edit that does not touch the password must not demand one.
  it "still lets the rest of the profile be edited without a password" do
    patch user_path(user), :params => { :user => { :phone_number => "+995 555 000000" } }

    expect(user.reload.phone_number).to eq("+995 555 000000")
  end

  # Product decision 2026-08-08: unlike signup (which mails the
  # server-generated password) and the reset flow (whose own mail is what
  # initiates it), an in-profile password change sends no mail at all. Using
  # `not_to change` rather than asserting `.deliveries` ends up empty: the
  # login above and this whole file don't clear the outbox, so a bare
  # emptiness check would be coupled to example/run ordering.
  it "does not send any mail when the password is changed" do
    expect {
      patch user_path(user), :params => { :user => { :current_password => "1234",
                                                     :password => "newpass",
                                                     :password_confirmation => "newpass" } }
    }.not_to change(ActionMailer::Base.deliveries, :size)
  end
end
