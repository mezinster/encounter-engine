# -*- encoding : utf-8 -*-
class NotificationMailer < ActionMailer::Base
  # Preserved verbatim from the Merb original (app/controllers/users.rb and
  # app/controllers/invitations.rb both hardcoded this same address). Not
  # part of Task 10's domain-configurability fix -- see the APP_HOST
  # override in app/views/notification_mailer/welcome_letter.text.erb for
  # what *is* being generalized (the mail body) and why "from" is
  # deliberately left alone (no feature exercises it, and the brief's
  # domain-wart callout was specifically about the mail body).
  default from: "noreply@bien.kg"

  def welcome_letter(user, password)
    @user = user
    @password = password
    mail_in_recipient_locale(user, :welcome_letter)
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
    mail_in_recipient_locale(team.captain, :reject_notification)
  end

  # Same shape as #reject_notification: @user is the user who accepted
  # (invitation.for_user -- named in the subject and body), the recipient
  # is invitation.to_team.captain.
  def accept_notification(user, team)
    @user = user
    mail_in_recipient_locale(team.captain, :accept_notification)
  end

  private

  # The recipient's locale governs the language of the mail, not the
  # sender's (request) locale -- a Russian-speaking captain inviting an
  # English-speaking player must not send them Russian. users.locale can be
  # nil/blank (e.g. accounts created before the i18n foundation task), so
  # this falls back to the application default locale, same as
  # config.i18n.fallbacks does for view rendering.
  def mail_in_recipient_locale(recipient, template)
    locale = recipient.locale.presence || I18n.default_locale

    I18n.with_locale(locale) do
      mail(to: recipient.email,
           subject: t("notification_mailer.#{template}.subject", **subject_vars),
           template_name: template)
    end
  end

  # Extra interpolation keys not referenced by a given subject string are
  # harmless (I18n ignores unused %{} vars), so one helper can serve all
  # four subjects rather than four bespoke var hashes.
  def subject_vars
    vars = {}
    vars[:nickname] = @user.nickname if @user
    vars[:team_name] = @team.name if @team
    vars
  end
end
