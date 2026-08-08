# -*- encoding : utf-8 -*-

# Merb::Mailer.deliveries -> ActionMailer::Base.deliveries.
#
# Semantics preserved from the Merb original: mail is counted PER ADDRESS, not
# globally. `Mail::Message#to` is an Array of address strings, exactly like
# Merb::Mailer's delivery struct, so the `include?` filter carries over
# unchanged.
#
# PARTIAL KNOWN VACUITY, LEFT AS-IS ON PURPOSE -- see the report.
# "никакие письма не должны быть высланы на X" has two kinds of caller. The
# direct one, features/invitations/reject-invitations.feature:37, passes a bare
# address and is a REAL, working assertion. The indirect one --
# features/invitations/steps/invitations_steps.rb:25, reached from the three
# "пользователь X не должен получить приглашение" sites in
# send-invitations.feature:62,73,82 -- interpolates the address with a trailing
# space, which the step's `(.*)$` capture keeps, so for those three the lookup
# can never match a real delivery and the assertion is always true. Adding a
# `.strip` here does make it mean what it says -- and then
# features/invitations/send-invitations.feature:64 fails, not because of an
# application bug but because the scenario's own setup ("пользователь Alisa
# состоит в команде Mushrooms") legitimately mails Alisa an invitation that is
# still sitting in the outbox when the assertion runs. The scenario is only
# satisfiable as "no NEW mail", and the feature files are the read-only
# contract, so the behaviour is preserved exactly as the Merb suite had it
# rather than reinterpreted here.
def deliveries_for(email)
  ActionMailer::Base.deliveries.select { |delivery| delivery.to.to_a.include?(email) }
end

# Merb::Mailer's delivery exposed the rendered text body as `#text`. The Rails
# equivalent is the decoded body: every NotificationMailer template is
# `*.text.erb` and the mailer passes `template_name:` with no HTML counterpart,
# so each message is single-part text/plain -- `#text_part` is nil and
# `body.decoded` is the text. `.decoded` (not `.body.to_s`) is required
# because the Russian bodies go out quoted-printable/base64 encoded; comparing
# against the raw encoded body would never match the Cyrillic in the feature
# files. `text_part ||` is kept so this still reads the right part if a
# multipart template is ever added.
def delivery_text(delivery)
  (delivery.text_part || delivery).body.decoded
end

Then %r{одно письмо с текстом "(.*)" должно быть выслано на ([^/\s]+)$}i do |text, email|
  deliveries = deliveries_for email
  expect(deliveries.size).to eq(1)
  expect(delivery_text(deliveries.last)).to match(/#{text}/)
end

# Added 2026-08-08 for features/signup/signup.feature's "Удачная регистрация"
# scenario (see CLAUDE.md, "The acceptance-suite rule", third authorised
# exception): signup no longer collects a password, so the scenario can't
# name a fixed value the welcome letter is expected to carry -- it can only
# assert that a letter was sent at all.
Then %r{одно письмо должно быть выслано на ([^/\s]+)$}i do |email|
  expect(deliveries_for(email).size).to eq(1)
end

Then %r{никакие письма не должны быть высланы$}i do
  expect(ActionMailer::Base.deliveries).to be_empty
end

Then %r{никакие письма не должны быть высланы на (.*)$}i do |email|
  expect(deliveries_for(email)).to be_empty
end

Given %r{все отосланные к этому моменту письма прочитаны$}i do
  ActionMailer::Base.deliveries.clear
end
