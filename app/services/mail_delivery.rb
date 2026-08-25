# -*- encoding : utf-8 -*-
#
# The rescue seam between a controller and SMTP.
#
# Every mail in this app is delivered synchronously inside the request
# (config.active_job.queue_adapter = :inline, and raise_delivery_errors is
# Rails' default true), so before this class existed an SMTP failure was an
# exception in a controller. In UsersController#create that committed a user
# row, lost the session cookie (ShowExceptions sits ABOVE Session::CookieStore
# in the middleware stack, so the session is never written), and destroyed the
# only copy of a generated password. See
# docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md §0.1.
#
# NOT namespaced as Mail::Delivery: the `mail` gem owns the top-level ::Mail
# constant, and app/services/mail/delivery.rb would have Zeitwerk reopen the
# gem's module.
require "net/smtp"
require "openssl"

class MailDelivery
  # Net::SMTPError is a MODULE, not a class. It is mixed into five error
  # classes with five DIFFERENT superclasses (Net::ProtoAuthError,
  # Net::ProtoServerError, Net::ProtoSyntaxError, Net::ProtoFatalError,
  # Net::ProtoUnknownError) -- there is no common ancestor class to rescue.
  # `rescue` dispatches with Module#===, which is why naming the module works.
  #
  # Net::OpenTimeout descends from Timeout::Error, NOT IOError, so it needs its
  # own entry -- and it is the single most likely failure here, since a
  # blackholed connection is more common than a refused one.
  #
  # The `require "net/smtp"` above is load-bearing. The mail gem requires
  # net/smtp lazily, only when SMTP delivery actually runs, and development and
  # test both use delivery_method = :test -- so Net::SMTPError is undefined in
  # a booted app. Without the require this array raises NameError at class-load
  # time in test and development while working perfectly in production.
  TRANSPORT_ERRORS = [
    Net::SMTPError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
    OpenSSL::SSL::SSLError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ETIMEDOUT,
    Errno::ENETUNREACH
  ].freeze

  # An SMTP rejection quotes the offending recipient back at you, so the
  # message is truncated rather than logged whole -- log aggregation is not
  # where anyone's address should end up.
  MESSAGE_LIMIT = 200

  # Yields, and reports whether the mail got out.
  #
  #   MailDelivery.attempt { NotificationMailer.welcome_letter(u, p).deliver_now }
  #   # => true | false
  #
  # Deliberately NOT rescuing StandardError. See the spec.
  def self.attempt
    yield
    true
  rescue *TRANSPORT_ERRORS => e
    Rails.logger.error(
      "[mail] delivery failed: #{e.class}: #{e.message.to_s[0, MESSAGE_LIMIT]}"
    )
    false
  end
end
