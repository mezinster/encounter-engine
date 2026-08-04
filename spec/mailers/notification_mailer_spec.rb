# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe NotificationMailer do
  let(:user) do
    User.create!(nickname: "iv", email: "iv@diesel.kg",
                 password: "1234", password_confirmation: "1234",
                 locale: "en")
  end

  describe "#welcome_letter" do
    it "addresses the welcome letter to the user" do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.to).to eq(["iv@diesel.kg"])
    end

    it "writes the letter in the recipient's locale, not the sender's" do
      I18n.with_locale(:ru) do
        mail = described_class.welcome_letter(user, "1234")
        expect(mail.subject).to eq(I18n.t("notification_mailer.welcome_letter.subject",
                                           host: "bien.kg", locale: :en))
      end
    end

    it "includes the plaintext password in the body (features/signup/signup.feature:27)" do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.body.encoded).to match(/1234/)
    end

    # The Merb-era spec.mailers.notification_mailer/welcome_letter_spec.rb
    # asserted this too ("contains email"); restoring it here so the
    # coverage isn't lost in the port.
    it "includes the user's email in the body" do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.body.encoded).to match(/iv@diesel\.kg/)
    end

    it "defaults the hardcoded-domain sentence to bien.kg, unchanged from the pre-port template" do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.body.encoded).to match(/bien\.kg/)
    end

    it "names the same host in the subject as in the body" do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.subject).to match(/bien\.kg/)
    end

    it "lets the domain be overridden per-instance via APP_HOST, in both subject and body" do
      with_env("APP_HOST" => "example-instance.org") do
        mail = described_class.welcome_letter(user, "1234")
        expect(mail.body.encoded).to match(/example-instance\.org/)
        expect(mail.subject).to match(/example-instance\.org/)
      end
    end

    it "lets the from address be overridden per-instance via MAIL_FROM" do
      with_env("MAIL_FROM" => "hello@example-instance.org") do
        mail = described_class.welcome_letter(user, "1234")
        expect(mail.from).to eq(["hello@example-instance.org"])
      end
    end

    it "defaults the from address to noreply@bien.kg, unchanged from the pre-port controllers" do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.from).to eq(["noreply@bien.kg"])
    end
  end

  describe "#invitation_notification" do
    let(:team) { Team.create!(name: "Mushrooms", captain: create_captain) }

    it "is addressed to the invited user and names the team, in the recipient's locale" do
      I18n.with_locale(:ru) do
        mail = described_class.invitation_notification(user, team)
        expect(mail.to).to eq(["iv@diesel.kg"])
        expect(mail.subject).to eq(I18n.t("notification_mailer.invitation_notification.subject",
                                           team_name: "Mushrooms", locale: :en))
        expect(mail.body.encoded).to match(/Mushrooms/)
      end
    end

    def create_captain
      User.create!(nickname: "noel", email: "noel@diesel.kg",
                   password: "1234", password_confirmation: "1234")
    end
  end

  describe "#accept_notification" do
    it "is addressed to the team captain and names the accepting user (features/invitations/accept-invitations.feature:17)" do
      captain = User.create!(nickname: "noel", email: "noel@diesel.kg",
                              password: "1234", password_confirmation: "1234", locale: "ru")
      team = Team.create!(name: "Mushrooms", captain: captain)
      alisa = User.create!(nickname: "Alisa", email: "alisa@diesel.kg",
                            password: "1234", password_confirmation: "1234")

      mail = described_class.accept_notification(alisa, team)

      expect(mail.to).to eq(["noel@diesel.kg"])
      expect(mail.subject).to match(/Пользователь Alisa принял Ваше приглашение/)
    end
  end

  describe "#reject_notification" do
    it "is addressed to the team captain and names the rejecting user (features/invitations/accept-invitations.feature:33)" do
      captain = User.create!(nickname: "iv2", email: "iv@diesel.kg",
                              password: "1234", password_confirmation: "1234", locale: "ru")
      team = Team.create!(name: "Плакучие Ивы", captain: captain)
      alisa = User.create!(nickname: "Alisa", email: "alisa2@diesel.kg",
                            password: "1234", password_confirmation: "1234")

      mail = described_class.reject_notification(alisa, team)

      expect(mail.to).to eq(["iv@diesel.kg"])
      expect(mail.subject).to match(/Пользователь Alisa отказался от приглашения/)
    end
  end

  # Saves and restores each var's *prior* value (not just ENV.delete), so a
  # developer who happens to already export APP_HOST or MAIL_FROM in their
  # shell doesn't see this example corrupt it for the rest of the process,
  # or see unrelated examples fail because a bare ENV.delete wiped a value
  # that was there before the test ran.
  def with_env(vars)
    previous = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
