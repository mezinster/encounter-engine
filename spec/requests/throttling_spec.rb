require "rails_helper"

describe "throttling the endpoints that send mail", type: :request do
  # Rails.cache is process-global and is cleared before every example by
  # spec/rails_helper.rb -- without that these counters leak into each other.

  describe "signup" do
    def sign_up(nickname)
      post users_path, :params => { :user => { :nickname => nickname,
                                               :email => "#{nickname}@example.com" } }
    end

    it "allows submissions up to the configured limit" do
      Setting.put("signup_max", 3)

      expect {
        3.times { |i| sign_up("user#{i}") }
      }.to change { User.count }.by(3)
    end

    it "refuses the one past the limit, creating no user and sending no mail" do
      Setting.put("signup_max", 2)
      2.times { |i| sign_up("early#{i}") }

      expect {
        expect {
          sign_up("late")
        }.not_to change { User.count }
      }.not_to change { ActionMailer::Base.deliveries.size }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include("Слишком много попыток")
    end

    # 0 is the documented "off" switch and an operator will reach for it during
    # an incident. If it read as "allow nothing" the console would brick signup
    # at the exact moment someone was trying to fix something.
    it "treats a limit of zero as disabled, not as blocking everything" do
      Setting.put("signup_max", 0)

      expect { 6.times { |i| sign_up("many#{i}") } }.to change { User.count }.by(6)
    end

    it "counts per client address, so one abuser does not lock out everyone" do
      Setting.put("signup_max", 1)

      post users_path, :params => { :user => { :nickname => "a", :email => "a@example.com" } },
                       :headers => { "REMOTE_ADDR" => "203.0.113.10" }

      expect {
        post users_path, :params => { :user => { :nickname => "b", :email => "b@example.com" } },
                         :headers => { "REMOTE_ADDR" => "203.0.113.11" }
      }.to change { User.count }.by(1)
    end
  end

  describe "password reset" do
    # create_user takes NO arguments (spec/spec_helpers/fixtures_helper.rb:18)
    # -- it generates its own nickname and email. Passing a hash raises
    # ArgumentError.
    let!(:user) { create_user }

    it "refuses past the limit and sends no further mail" do
      Setting.put("reset_max", 2)
      2.times { post password_resets_path, :params => { :email => user.email } }

      expect {
        post password_resets_path, :params => { :email => user.email }
      }.not_to change { ActionMailer::Base.deliveries.size }

      expect(response).to have_http_status(:too_many_requests)
    end

    # The refusal must not become an oracle: the un-throttled path deliberately
    # answers identically for a registered and an unregistered address
    # (password_resets_controller.rb), and a throttle that only counted real
    # users would undo that.
    it "throttles an unregistered address the same way" do
      Setting.put("reset_max", 1)
      post password_resets_path, :params => { :email => "nobody@example.com" }

      post password_resets_path, :params => { :email => "nobody@example.com" }
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  # F6: AccessCodeRedemptionsController#create calls throttle!, but nothing
  # exercised that call -- deleting it failed nothing. Unlike signup/reset,
  # this endpoint answers with a redirect and its own flash message rather
  # than a bare 429, so the refusal is asserted through the flash instead.
  describe "access code redemption" do
    let(:captain) { create_user }
    let(:team)    { create_team(:captain => captain) }
    let(:game)    { create_game(:is_draft => false, :access_mode => "pass_required") }

    def sign_in(user)
      put login_path, :params => { :email => user.email, :password => "1234" }
    end

    it "refuses past the configured limit, creating no pass" do
      Setting.put("access_code_redemption_max", 1)
      team
      sign_in(captain)
      _code, raw = create_access_code(:game => game)

      # Trips the counter without redeeming anything, so the SECOND request
      # below is refused for being over the limit, not for an unknown code.
      post redeem_access_code_path, :params => { :access_code => "ZZZZZZZZZZ" }

      expect { post redeem_access_code_path, :params => { :access_code => raw } }
        .not_to change { AccessPass.count }
      expect(flash[:alert]).to include("Слишком много попыток")
    end
  end
end
