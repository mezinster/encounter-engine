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
  # EOFError and Errno::EPIPE cover the peer closing the connection outright --
  # a greylisting relay, an over-quota Gmail dropping the session right after
  # its 220 greeting, a load balancer reaping an idle connection. Errno::ECONNRESET
  # above only covers an RST; a clean FIN (the far more common shape of "the
  # other end hung up") surfaces to net/protocol.rb as a bare EOFError on read,
  # or Errno::EPIPE if this process is still writing when the peer is already
  # gone. Neither is caught by ECONNRESET. Reproduced against a real socket
  # (server greets 220 then closes; server accepts then closes) -- both raised
  # EOFError, uncaught, before these two entries were added.
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
    Errno::ENETUNREACH,
    EOFError,
    Errno::EPIPE
  ].freeze

  # An SMTP rejection quotes the offending recipient back at you, and
  # TRUNCATION DOES NOT REMOVE IT -- that was this design's own bug, caught by a
  # security review after the first implementation shipped. A real rejection
  # ("550 5.1.1 <ivan@example.com>: Recipient address rejected: User unknown")
  # is about 70 characters, far under any sane cap, so the address survived
  # intact while a comment claimed otherwise. MESSAGE_LIMIT bounds the log
  # line's LENGTH; redaction is what protects the address. Keep both, and do
  # not "simplify" this back to truncation alone.
  EMAIL_PATTERN = /[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/
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
    Rails.logger.error("[mail] delivery failed: #{e.class}: #{redact(e.message)}")
    false
  end

  # Addresses out, diagnosis in: the SMTP code and the reason text are the whole
  # reason this line exists, so redaction must not eat them.
  def self.redact(message)
    message.to_s.gsub(EMAIL_PATTERN, "[address]")[0, MESSAGE_LIMIT]
  end
end
