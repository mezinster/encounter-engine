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

  # describe_mail/#deliver drove the Merb-era per-template mailer specs
  # (spec/mailers/notification_mailer/*_spec.rb) via
  # Merb::MailController#dispatch_and_deliver, an API ActionMailer doesn't
  # have. Task 10 replaced that suite with spec/mailers/notification_mailer_spec.rb,
  # written directly against NotificationMailer's ActionMailer interface, so
  # nothing calls describe_mail anymore. Left in place (dead code) rather
  # than deleted, since porting it isn't this task's job and nothing
  # references it.
  def describe_mail(mailer, template, &block)
    describe "/#{mailer.to_s.downcase}/#{template}" do
      before :each do
        @mailer_class, @template = mailer, template
        @assigns = {}
        clear_mail_deliveries
      end

      def deliver(send_params={}, mail_params={})
        mail_params = {:from => "from@example.com", :to => "to@example.com", :subject => "Please activate your account"}.merge(mail_params)
        @mailer_class.new(send_params).dispatch_and_deliver @template.to_sym, mail_params
        @mail = ActionMailer::Base.deliveries.last
      end

      instance_eval(&block)
    end
  end
end
