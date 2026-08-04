# -*- encoding : utf-8 -*-
Before do
  clear_mail_deliveries
  set_common_password
end

def clear_mail_deliveries
  # Merb::Mailer.deliveries -> ActionMailer::Base.deliveries.
  #
  # cucumber-rails resets deliveries in a Before hook of its own
  # (lib/cucumber/rails/hooks/mail.rb), but hook ordering across files is not
  # worth relying on and features/steps/mail_steps.rb counts mail per address
  # on the assumption that a scenario starts from an empty outbox. Keep the
  # explicit clear the Merb suite had.
  ActionMailer::Base.deliveries.clear
end

# `recreate_database` (ActiveRecordHelper.recreate_database!, from
# merb_cucumber) is gone: database isolation is now a per-scenario transaction
# rollback, installed by the Around hook in features/support/env.rb.

def set_common_password
  @the_password = "1234"
end
