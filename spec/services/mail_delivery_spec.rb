# -*- encoding : utf-8 -*-
require "rails_helper"

# The value of this class is entirely in WHICH errors it swallows, so both
# directions are pinned: transport failures return false, and everything else
# still raises. A rescue later widened to StandardError passes every example
# that only checks the first half -- which is why the second half exists.
describe MailDelivery do
  describe "transport failures" do
    # Constructed from plain strings; none of these needs a real SMTP
    # conversation. Verified 2026-08-25 against ruby 3.3.12.
    {
      "Net::SMTPAuthenticationError" => Net::SMTPAuthenticationError.new("535 5.7.8 Username and Password not accepted"),
      "Net::SMTPFatalError"          => Net::SMTPFatalError.new("550 5.4.5 Daily user sending limit exceeded"),
      "Net::SMTPServerBusy"          => Net::SMTPServerBusy.new("421 Try again later"),
      "Net::SMTPSyntaxError"         => Net::SMTPSyntaxError.new("501 Syntax error"),
      "Net::SMTPUnknownError"        => Net::SMTPUnknownError.new("Unknown response"),
      "Net::OpenTimeout"             => Net::OpenTimeout.new("execution expired"),
      "Net::ReadTimeout"             => Net::ReadTimeout.new,
      "SocketError"                  => SocketError.new("getaddrinfo: Name or service not known"),
      "OpenSSL::SSL::SSLError"       => OpenSSL::SSL::SSLError.new("SSL_connect returned=1"),
      "Errno::ECONNREFUSED"          => Errno::ECONNREFUSED.new,
      "Errno::ECONNRESET"            => Errno::ECONNRESET.new,
      "Errno::EHOSTUNREACH"          => Errno::EHOSTUNREACH.new,
      "Errno::ETIMEDOUT"             => Errno::ETIMEDOUT.new,
      "Errno::ENETUNREACH"           => Errno::ENETUNREACH.new
    }.each do |name, error|
      it "returns false for #{name}" do
        expect(described_class.attempt { raise error }).to eq(false)
      end
    end
  end

  describe "everything else" do
    # These MUST still blow up. A missing translation key or a typo in a mailer
    # template is a bug to fix, not weather to survive; swallowing it trades a
    # visible outage for an invisible one.
    it "lets a NoMethodError through" do
      expect { described_class.attempt { raise NoMethodError, "undefined method" } }
        .to raise_error(NoMethodError)
    end

    it "lets a missing translation through" do
      expect { described_class.attempt { raise I18n::MissingTranslationData.new(:ru, "x", {}) } }
        .to raise_error(I18n::MissingTranslationData)
    end
  end

  it "returns true when the block completes" do
    expect(described_class.attempt { :delivered }).to eq(true)
  end

  # Truncation alone did NOT do this. The realistic sample below is 96
  # characters, well under MESSAGE_LIMIT, so the cap removes nothing at all --
  # which is why the original "truncated, so the address is safe" comment was
  # wrong, and why this example exists rather than a length assertion alone.
  it "keeps addresses out of the log while keeping the diagnosis in" do
    allow(Rails.logger).to receive(:error)

    described_class.attempt do
      raise Net::SMTPFatalError.new(
        "550 5.1.1 <ivan@example.com>: Recipient address rejected: User unknown"
      )
    end

    expect(Rails.logger).to have_received(:error) do |line|
      expect(line).not_to include("ivan@example.com")
      expect(line).to include("550 5.1.1")
      expect(line).to include("Recipient address rejected")
    end
  end

  it "logs the error class and a truncated message" do
    allow(Rails.logger).to receive(:error)

    described_class.attempt { raise Net::SMTPFatalError.new("550 " + ("x" * 500)) }

    expect(Rails.logger).to have_received(:error) do |line|
      expect(line).to include("Net::SMTPFatalError")
      expect(line.length).to be < 300
    end
  end
end
