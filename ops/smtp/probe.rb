#!/usr/bin/env ruby
# frozen_string_literal: true

# Proves that the app's SMTP credentials still authenticate -- and that the
# warm spare's do too -- without sending a single message.
#
# Nothing is ever delivered. A probe that mailed a real address to prove mail
# works would spend the sending reputation this whole design exists to protect.
#
# Split the same way ops/vmscale does it: `check` talks to the network, and
# `classify` is a pure function from results to a verdict, so the decision is
# testable from fixtures with no SMTP server anywhere.
#
# See docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md §D7
# and docs/runbooks/smtp-failover.md.

require "net/smtp"
require "json"

module SMTPProbe
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 10
  MESSAGE_LIMIT = 200

  # Redacted BEFORE the message enters the result hash, because that hash is
  # published, not merely logged: .github/workflows/smtp-probe.yml embeds this
  # JSON verbatim in a GitHub issue body, and this repository is public. Some
  # servers echo the authenticating address back in an auth failure, so a
  # truncate-only approach would put it on the open internet.
  #
  # Not shared with MailDelivery::EMAIL_PATTERN: this script runs on a bare CI
  # runner and must never require Rails.
  EMAIL_PATTERN = /[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/

  module_function

  def redact(message)
    message.to_s.gsub(EMAIL_PATTERN, "[address]")[0, MESSAGE_LIMIT]
  end

  # Connects, STARTTLS, AUTH, QUIT. Sends nothing.
  def check(role:, address:, port:, user_name:, password:, helo_domain:)
    return { "role" => role, "configured" => false, "ok" => false } if
      address.to_s.empty? || user_name.to_s.empty? || password.to_s.empty?

    smtp = Net::SMTP.new(address, port.to_i)
    smtp.open_timeout = OPEN_TIMEOUT
    smtp.read_timeout = READ_TIMEOUT
    smtp.enable_starttls_auto

    # Net::SMTP#start's FIRST positional argument is the HELO/EHLO domain --
    # the name this client announces itself as -- not the server it is
    # talking to. Passing `address` here made the probe announce itself as
    # smtp.gmail.com while talking to smtp.gmail.com. Gmail and Fastmail
    # tolerate that, but a relay with a reject_unknown_helo_hostname-style
    # policy would not, and the failure would be a false "down": an alarm
    # for the probe's own bug. Production gets this right already --
    # config/environments/production.rb passes domain: ENV.fetch("APP_HOST").
    smtp.start(helo_domain, user_name, password, :plain) { }
    { "role" => role, "configured" => true, "ok" => true }
  rescue StandardError => e
    # StandardError is correct HERE, unlike in MailDelivery: this script's only
    # job is to report what went wrong, and every failure mode is interesting.
    { "role" => role, "configured" => true, "ok" => false,
      "error_class" => e.class.to_s, "error" => redact(e.message) }
  end

  # Pure. results -> verdict.
  def classify(results)
    primary = results.find { |r| r["role"] == "primary" }
    spare   = results.find { |r| r["role"] == "spare" }

    failures = results.select { |r| r["configured"] && !r["ok"] }
    notes    = []
    notes << "primary not configured" if primary && !primary["configured"]
    notes << "spare not configured" if spare && !spare["configured"]

    verdict =
      if primary.nil? || !primary["ok"]
        "down"
      elsif spare && spare["configured"] && !spare["ok"]
        "degraded"
      else
        "ok"
      end

    summary =
      if failures.empty?
        (["all configured SMTP endpoints authenticate"] + notes).join("; ")
      else
        described = failures.map { |f| "#{f['role']}: #{f['error_class']} #{f['error']}" }
        (described + notes).join("; ")
      end

    { "verdict" => verdict, "summary" => summary, "failures" => failures }
  end
end

if $PROGRAM_NAME == __FILE__
  # Same HELO domain for both endpoints: it identifies this client (the app),
  # not whichever server it happens to be talking to right now.
  #
  # `|| "game.mezin.eu"` alone guards only an UNSET APP_HOST. The workflow's
  # `cfg` step writes `app_host=` unconditionally (smtp-probe.yml), and a
  # GitHub Actions `env:` populated from an empty step output is "", not
  # unset -- so ENV["APP_HOST"] would read as "" and the `||` would not fire,
  # sending a bare `EHLO `. .to_s.empty? treats unset and empty the same way.
  helo_domain = ENV["APP_HOST"].to_s.empty? ? "game.mezin.eu" : ENV["APP_HOST"]

  results = [
    SMTPProbe.check(role: "primary",
                    address:     ENV["SMTP_ADDRESS"] || "smtp.gmail.com",
                    port:        ENV["SMTP_PORT"] || 587,
                    user_name:   ENV["SMTP_USERNAME"],
                    password:    ENV["SMTP_PASSWORD"],
                    helo_domain: helo_domain),
    SMTPProbe.check(role: "spare",
                    address:     ENV["SMTP_SPARE_ADDRESS"],
                    port:        ENV["SMTP_SPARE_PORT"] || 587,
                    user_name:   ENV["SMTP_SPARE_USERNAME"],
                    password:    ENV["SMTP_SPARE_PASSWORD"],
                    helo_domain: helo_domain)
  ]

  verdict = SMTPProbe.classify(results)
  puts JSON.pretty_generate(verdict)
  exit(verdict["verdict"] == "ok" ? 0 : 1)
end
