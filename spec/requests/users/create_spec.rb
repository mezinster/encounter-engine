# -*- encoding : utf-8 -*-
require "rails_helper"

# Ported from the Merb-era request spec of the same name, which drove the app
# through merb-core's `request(resource(:users), method: "POST", params: ...)`
# helper and asserted against a Merb response object. Both are gone; this is
# the same coverage expressed as a Rails request spec.
#
# It is ported rather than deleted because it is the only test that exercises
# signup end-to-end through the real stack, and two of its assertions exist
# nowhere else in the suite:
#   * the welcome letter -- spec/controllers/users/create_spec.rb neither
#     renders views nor looks at ActionMailer::Base.deliveries;
#   * the Russian validation copy actually reaching the re-rendered signup
#     form, which requires error_messages_for to run for real.
#
# Three deliberate differences from the original:
#   * `@response.should be_successful` on the failure cases becomes
#     :unprocessable_entity. Merb re-rendered a rejected form with 200;
#     UsersController#create returns 422, which spec/controllers/users/
#     create_spec.rb already asserts.
#   * NICKNAME/EMAIL/PASSWORD were bare constants written inside describe
#     blocks, so they leaked onto Object and Ruby warned about redefinition.
#     They are `let`s now.
#   * `User.delete_all` in every before block is dropped: rails_helper sets
#     use_transactional_fixtures, so each example already starts clean.
RSpec.describe "POST /users", type: :request do
  let(:nickname) { "valid" }
  let(:email) { "#{nickname}@email.com" }
  let(:password) { "1234" }

  def perform_request(nickname, email, password, password_confirmation)
    post users_path, params: {
      user: { nickname: nickname, email: email,
              password: password, password_confirmation: password_confirmation }
    }
  end

  before { clear_mail_deliveries }

  describe "regular case" do
    before { perform_request(nickname, email, password, password) }

    it "redirects to dashboard" do
      expect(response).to redirect_to(dashboard_path)
    end

    it "creates a user" do
      expect(User.exists?(email: email)).to be_truthy
    end

    it "delivers a welcome letter" do
      # `.text` on Merb's delivery struct becomes `.body.decoded`: the template
      # is single-part text/plain, transfer-encoded because the body is
      # Cyrillic, so the raw body would not match either interpolation.
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(last_delivered_mail.to.first).to eq(email)
      expect(last_delivered_mail.body.decoded).to match(/#{email}/)
      expect(last_delivered_mail.body.decoded).to match(/#{password}/)
    end
  end

  describe "email already registered" do
    before do
      User.create!(nickname: nickname, email: email,
                   password: "sekrit", password_confirmation: "sekrit")
      perform_request(nickname, email, password, password)
    end

    it "re-renders the form" do
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "does not create another user" do
      expect(User.count).to eq(1)
    end

    it "shows a error message" do
      expect(response.body).to include("уже зарегистрирован")
    end

    it "does not deliver email" do
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe "password confirmation does not match" do
    before { perform_request(nickname, email, password, "oooops") }

    it "re-renders the form" do
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "does not create a user" do
      expect(User.count).to eq(0)
    end

    it "shows a error message" do
      expect(response.body).to include("Пароль и его подтверждение не совпадают")
    end

    it "does not deliver email" do
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe "invalid email" do
    before { perform_request(nickname, "invalid-mail-booooo", password, password) }

    it "re-renders the form" do
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "does not create a user" do
      expect(User.count).to eq(0)
    end

    it "shows a error message" do
      expect(response.body).to include("Неправильный формат")
    end

    it "does not deliver email" do
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
