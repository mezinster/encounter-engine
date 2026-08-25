# -*- encoding : utf-8 -*-
require "rails_helper"

# What these examples protect is stated in
# docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md §0.1: with
# SMTP down, signup used to commit a user row, fail to write the session
# cookie, and lose the only copy of a server-generated password -- an account
# nobody could ever log into, whose e-mail address was now taken.
describe "when SMTP is down", type: :request do
  # Raised from the delivery itself, so MailDelivery's own rescue is exercised
  # rather than stubbed away.
  def break_smtp!
    allow_any_instance_of(ActionMailer::MessageDelivery)
      .to receive(:deliver_now)
      .and_raise(Net::SMTPAuthenticationError.new("535 5.7.8 Username and Password not accepted"))
  end

  describe "signup" do
    it "keeps the account and shows the generated password" do
      break_smtp!

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      user = User.find_by(:email => "aldor@diesel.kg")
      expect(user).to be_present

      expect(response.status).to eq(200)
      # The password is the point. Read it back off the record's own digest
      # rather than guessing: whatever string is on screen must be the one
      # that actually authenticates.
      shown = response.body[%r{<code class="generated-password">([^<]+)</code>}, 1]
      expect(shown).to be_present
      expect(user.authenticate(shown)).to be_truthy
    end

    it "does not let that page be cached" do
      break_smtp!

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "still signs the user in" do
      break_smtp!

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }
      get dashboard_path

      expect(response.status).to eq(200)
    end

    it "redirects to the dashboard as usual when the letter goes out" do
      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      expect(response).to redirect_to(dashboard_path)
    end

    it "never writes the generated password to the log" do
      break_smtp!
      logged = []
      allow(Rails.logger).to receive(:error) { |line| logged << line }

      post users_path, :params => { :user => { :nickname => "Aldor", :email => "aldor@diesel.kg" } }

      shown = response.body[%r{<code class="generated-password">([^<]+)</code>}, 1]
      expect(logged.join("\n")).not_to include(shown)
      expect(logged.join("\n")).to include("Net::SMTPAuthenticationError")
    end
  end

  # THE important example in this file.
  #
  # PasswordResetsController#create sends only inside `if user`, so an SMTP
  # exception fires ONLY when the address is registered. Any failure response
  # that differs from the success response therefore answers the question
  # "is this address registered?" -- rebuilding exactly the oracle that
  # controller's identical-response design exists to prevent, and that
  # SessionsController#create refuses to answer at login.
  describe "password reset" do
    it "answers identically for a registered and an unregistered address" do
      break_smtp!
      user = create_user

      post password_resets_path, :params => { :email => user.email }
      registered = [response.status, response.location, flash[:notice]]

      post password_resets_path, :params => { :email => "nobody-at-all@example.com" }
      unregistered = [response.status, response.location, flash[:notice]]

      expect(registered).to eq(unregistered)
    end

    it "still issues the token, so a later retry can use it" do
      break_smtp!
      user = create_user

      post password_resets_path, :params => { :email => user.email }

      expect(user.reload.reset_password_token_digest).to be_present
    end
  end

  describe "invitations" do
    def sign_in(user)
      put login_path, :params => { :email => user.email, :password => "1234" }
    end

    it "creates the invitation and says the email did not go out" do
      captain = create_user
      create_team(:captain => captain)
      player = create_user
      sign_in(captain)
      break_smtp!

      post invitations_path, :params => { :invitation => { :recepient_nickname => player.nickname } }

      expect(Invitation.count).to eq(1)
      expect(flash[:notice]).to eq(
        I18n.t("invitations.notice_sent_unnotified", :nickname => player.nickname, :locale => :ru)
      )
    end

    # The regression test for a bug that fixes itself. Before MailDelivery, the
    # mailer on line 37 raised, which skipped reject_rest_of_invitations
    # entirely: the player was on the team, and every OTHER captain who had
    # invited them kept a stale invitation and heard nothing.
    it "still auto-rejects the other invitations when the mailer fails" do
      player  = create_user
      team_a  = create_team(:captain => create_user)
      team_b  = create_team(:captain => create_user)
      invite_a = Invitation.create!(:to_team => team_a, :recepient_nickname => player.nickname)
      Invitation.create!(:to_team => team_b, :recepient_nickname => player.nickname)
      sign_in(player)
      break_smtp!

      post accept_invitation_path(invite_a)

      expect(Invitation.count).to eq(0)
      expect(player.reload.team).to eq(team_a)
      expect(flash[:alert]).to eq(I18n.t("invitations.accept_unnotified", :locale => :ru))
    end
  end
end
