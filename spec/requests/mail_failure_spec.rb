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
end
