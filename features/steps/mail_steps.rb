# -*- encoding : utf-8 -*-

# Merb::Mailer.deliveries -> ActionMailer::Base.deliveries.
#
# Semantics preserved from the Merb original: mail is counted PER ADDRESS, not
# globally. `Mail::Message#to` is an Array of address strings, exactly like
# Merb::Mailer's delivery struct, so the `include?` filter carries over
# unchanged.
#
# KNOWN VACUITY, LEFT AS-IS ON PURPOSE -- see the report.
# The only caller of "никакие письма не должны быть высланы на X"
# (features/invitations/steps/invitations_steps.rb:25) passes the address with
# a trailing space, which the step's `(.*)$` capture keeps, so the lookup can
# never match a real delivery and the assertion is always true. Adding a
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

Then %r{никакие письма не должны быть высланы$}i do
  expect(ActionMailer::Base.deliveries).to be_empty
end

Then %r{никакие письма не должны быть высланы на (.*)$}i do |email|
  expect(deliveries_for(email)).to be_empty
end

Given %r{все отосланные к этому моменту письма прочитаны$}i do
  ActionMailer::Base.deliveries.clear
end
