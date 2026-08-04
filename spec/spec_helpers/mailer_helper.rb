# -*- encoding : utf-8 -*-
module MailerHelper
  def assert_sends_email(&block)
    block.should change(ActionMailer::Base.deliveries, :size).by(1)
  end

  def clear_mail_deliveries
    ActionMailer::Base.deliveries.clear
  end

  def last_delivered_mail
    ActionMailer::Base.deliveries.last
  end
end
