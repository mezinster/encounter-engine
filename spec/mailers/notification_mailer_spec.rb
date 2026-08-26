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

    # Product decision 2026-08-08: with signup no longer collecting a
    # password (the server generates it), the welcome letter is the only
    # place the user ever sees it -- so it must also tell them to change it.
    # `user` here has locale: "en" (see the let above).
    it "urges the user to change the generated password promptly" do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.body.encoded).to match(/change this password/i)
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

    # A captainless team is a valid model state -- captain_id is nullable and
    # Team declares `belongs_to :captain, optional: true` -- and the team
    # membership programme makes it reachable. This dereferenced
    # team.captain.locale and .email, and InvitationsController#accept calls
    # it AFTER joining the invitee and deleting the invitation, so the crash
    # left a partial commit plus an error page.
    it "delivers nothing, rather than raising, when the team has no captain" do
      team = Team.create!(:name => "Безголовые")
      alisa = User.create!(:nickname => "Alisa3", :email => "alisa3@diesel.kg",
                           :password => "1234", :password_confirmation => "1234")

      expect do
        described_class.accept_notification(alisa, team).deliver_now
      end.not_to change { ActionMailer::Base.deliveries.count }
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

    # See the captainless case in #accept_notification above -- #reject has
    # the same shape and the same crash.
    it "delivers nothing, rather than raising, when the team has no captain" do
      team = Team.create!(:name => "Безголовые-2")
      alisa = User.create!(:nickname => "Alisa4", :email => "alisa4@diesel.kg",
                           :password => "1234", :password_confirmation => "1234")

      expect do
        described_class.reject_notification(alisa, team).deliver_now
      end.not_to change { ActionMailer::Base.deliveries.count }
    end
  end

  # Two shapes, distinguished by whether a team is passed -- the same
  # distinction TestAdmission draws with user_id. A solo admission's team is
  # the DISPOSABLE one (no members, no captain), which exists only because
  # users.team_id is a single column; naming it to the recipient would be
  # meaningless, so the solo mail never mentions a team at all.
  describe "#test_admission_notification" do
    let(:game) { create_game(:author => create_user, :name => "Ночной дозор") }

    it "addresses a solo tester's invitation to that tester" do
      mail = described_class.test_admission_notification(user, game, nil)
      expect(mail.to).to eq(["iv@diesel.kg"])
    end

    it "names the team in a team admission's subject" do
      team = create_team(:captain => create_user)
      mail = described_class.test_admission_notification(user, game, team)
      expect(mail.subject).to include(team.name)
    end

    it "names the team in a team admission's body" do
      team = create_team(:captain => create_user)
      mail = described_class.test_admission_notification(user, game, team)
      expect(mail.body.encoded).to include(team.name)
    end

    # A solo admission's team in the database is the DISPOSABLE one -- no
    # members, no captain, created only so the tester has somewhere to hang a
    # passing. Naming it to the recipient would be gibberish ("your team
    # Team#a7f3c1 has been invited"), so the caller passes nil, and this pins
    # that the body never grows a team sentence by accident.
    it "never mentions a team in a solo admission's body" do
      mail = described_class.test_admission_notification(user, game, nil)
      expect(mail.body.encoded).not_to match(/команд|team/i)
    end

    it "links the recipient to the play screen for that game" do
      mail = described_class.test_admission_notification(user, game, nil)
      expect(mail.body.encoded).to include("/play/#{game.id}")
    end

    it "writes the invitation in the recipient's locale, not the sender's" do
      I18n.with_locale(:ru) do
        mail = described_class.test_admission_notification(user, game, nil)
        expect(mail.subject).to eq(
          I18n.t("notification_mailer.test_admission_notification.subject_solo",
                 game_name: game.name, locale: :en)
        )
      end
    end
  end

  # The counterpart to #test_admission_notification: a tester who was told
  # they are in should be told when they are out, since they may well have
  # set an evening aside. Same two shapes, same nil-team convention.
  describe "#test_admission_revoked" do
    let(:game) { create_game(:author => create_user, :name => "Ночной дозор") }

    it "addresses a solo tester's revocation to that tester" do
      mail = described_class.test_admission_revoked(user, game, nil)
      expect(mail.to).to eq(["iv@diesel.kg"])
    end

    it "names the game in a solo revocation's subject" do
      mail = described_class.test_admission_revoked(user, game, nil)
      expect(mail.subject).to include(game.name)
    end

    it "names the team in a team revocation's subject" do
      team = create_team(:captain => create_user)
      mail = described_class.test_admission_revoked(user, game, team)
      expect(mail.subject).to include(team.name)
    end

    # Nothing to click any more -- the whole point of the mail is that the
    # play screen would now refuse them. A link would be a broken promise.
    it "offers no play link, because the access it announces is gone" do
      mail = described_class.test_admission_revoked(user, game, nil)
      expect(mail.body.encoded).not_to include("/play/")
    end

    it "writes the revocation in the recipient's locale, not the sender's" do
      I18n.with_locale(:ru) do
        mail = described_class.test_admission_revoked(user, game, nil)
        expect(mail.subject).to eq(
          I18n.t("notification_mailer.test_admission_revoked.subject_solo",
                 game_name: game.name, locale: :en)
        )
      end
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
