# -*- encoding : utf-8 -*-
class NotificationMailer < ActionMailer::Base
  # Fix round 1: this was hardcoded to "noreply@bien.kg" -- the same
  # single-instance-domain wart as the welcome letter body (see #app_host
  # below), just missed on the first pass. A Proc (not a plain string) is
  # required here: ActionMailer evaluates a plain `default from:` value once,
  # when this class body first runs, so a literal ENV.fetch(...) would freeze
  # in whatever MAIL_FROM was set (or unset) at boot/autoload time. A Proc is
  # re-evaluated on every #mail call, so it also picks up ENV changes made
  # after the class has already loaded -- which is what lets a spec exercise
  # the override at all. Default preserved as "noreply@bien.kg" so existing
  # deployments that don't set MAIL_FROM see no change in behavior.
  default from: -> { ENV.fetch("MAIL_FROM", "noreply@bien.kg") }

  def welcome_letter(user, password)
    @user = user
    @password = password
    @host = app_host
    mail_in_recipient_locale(user, :welcome_letter)
  end

  def password_reset(user, token)
    @user = user
    @host = app_host
    @token = token
    mail_in_recipient_locale(user, :password_reset)
  end

  # Recipient is the invited user (invitation.for_user); @team is the team
  # they were invited to (invitation.to_team), used for both subject and
  # body.
  def invitation_notification(user, team)
    @user = user
    @team = team
    mail_in_recipient_locale(user, :invitation_notification)
  end

  # Two distinct people are involved here: the person whose action
  # triggered the notice (invitation.for_user -- named in the subject and
  # body) and the recipient who should be told about it
  # (invitation.to_team.captain). The Merb original
  # (app/controllers/invitations.rb#send_reject_notification) captured both
  # by taking the whole `invitation` and reading
  # invitation.to_team.captain.email for :to plus invitation.for_user for
  # the template. A single `user` argument can't carry both, so this takes
  # the acting user plus the team and reads the captain off the team --
  # mirroring the (user, team) shape #invitation_notification already uses.
  def reject_notification(user, team)
    @user = user
    # A captainless team has nobody to notify. captain_id is nullable and
    # Team declares `belongs_to :captain, optional: true`, so this is a valid
    # state rather than a corrupt one -- and returning before `mail` yields
    # ActionMailer's NullMail, which makes the caller's deliver_now a no-op
    # without the caller having to know. Deliberately NOT fixed by reordering
    # InvitationsController#accept: that ordering is itself deliberate and
    # commented, and the defect is the unguarded dereference, not the
    # sequence.
    return if team.captain.nil?

    mail_in_recipient_locale(team.captain, :reject_notification)
  end

  # Same shape as #reject_notification: @user is the user who accepted
  # (invitation.for_user -- named in the subject and body), the recipient
  # is invitation.to_team.captain.
  def accept_notification(user, team)
    @user = user
    # See #reject_notification above for why this returns rather than
    # reordering the caller.
    return if team.captain.nil?

    mail_in_recipient_locale(team.captain, :accept_notification)
  end

  # Someone other than the author was admitted to a TESTING run. Two shapes,
  # the same distinction TestAdmission draws with user_id: a team admitted as
  # itself (team present) or one player admitted alone (team nil).
  #
  # A solo admission DOES have a team in the database -- the disposable one,
  # holding no members and no captain, which exists only because users.team_id
  # is a single column (see TestAdmission's class comment). It is an
  # implementation detail of the grant, not something the recipient has any
  # name for, so the caller passes nil and the mail never mentions a team.
  def test_admission_notification(user, game, team)
    @user = user
    @game = game
    @team = team
    @host = app_host
    mail_in_recipient_locale(user, :test_admission_notification,
                             :subject_key => team ? "subject_team" : "subject_solo")
  end

  # The counterpart grant-removal notice. Same (user, game, team) shape and
  # the same nil-means-solo convention as #test_admission_notification.
  #
  # The caller must build its recipient list BEFORE TestAdmission#revoke!
  # runs: revoking a solo admission destroys the disposable team along with
  # the row, so afterwards there is nothing left to read the recipients off.
  # TestAdmissionsController#revoke already does this for its flash label.
  def test_admission_revoked(user, game, team)
    @user = user
    @game = game
    @team = team
    @host = app_host
    mail_in_recipient_locale(user, :test_admission_revoked,
                             :subject_key => team ? "subject_team" : "subject_solo")
  end

  private

  # The recipient's locale governs the language of the mail, not the
  # sender's (request) locale -- a Russian-speaking captain inviting an
  # English-speaking player must not send them Russian. users.locale can be
  # nil/blank (e.g. accounts created before the i18n foundation task), so
  # this falls back to the application default locale, same as
  # config.i18n.fallbacks does for view rendering.
  def mail_in_recipient_locale(recipient, template, subject_key: "subject")
    locale = recipient.locale.presence || I18n.default_locale

    I18n.with_locale(locale) do
      mail(to: recipient.email,
           subject: t("notification_mailer.#{template}.#{subject_key}", **subject_vars),
           template_name: template)
    end
  end

  # Extra interpolation keys not referenced by a given subject string are
  # harmless (I18n ignores unused %{} vars), so one helper can serve all
  # four subjects rather than four bespoke var hashes.
  def subject_vars
    vars = { host: app_host }
    vars[:nickname] = @user.nickname if @user
    vars[:team_name] = @team.name if @team
    vars[:game_name] = @game.name if @game
    vars
  end

  # Fix round 1: the welcome letter's subject ("Регистрация на bienkg" --
  # "bienkg" typo included, verbatim from the Merb original controller) and
  # body used to name the domain two different ways: the body already went
  # through APP_HOST (see app/views/notification_mailer/welcome_letter.text.erb),
  # but the subject was still a static string with the old hardcoded,
  # misspelled host baked in, and the English translation didn't mention a
  # host at all -- ru and en said different things even though the leaf-key
  # sets matched. Centralizing host resolution here, used by both the
  # subject (via subject_vars) and the body (via @host), fixes both: one
  # source of truth, ru and en both say "registered at/on %{host}" now, and
  # interpolating the var naturally fixes the "bienkg" typo (renders with
  # the dot). Same ENV var and default as the body fix -- see
  # app/views/notification_mailer/welcome_letter.text.erb for why APP_HOST
  # and not a new name.
  def app_host
    ENV.fetch("APP_HOST", "bien.kg")
  end
end
