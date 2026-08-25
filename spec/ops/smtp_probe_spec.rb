# frozen_string_literal: true

require "spec_helper"
require_relative "../../ops/smtp/probe"

# classify is a pure function: no network, no clock, no Rails. Same reasoning as
# spec/ops/vmscale_policy_spec.rb -- the shell (or in this case Net::SMTP) does
# the talking, the Ruby does the deciding, and only the deciding is tested here.
RSpec.describe SMTPProbe do
  def ok(role)         = { "role" => role, "configured" => true, "ok" => true }
  def broken(role)     = { "role" => role, "configured" => true, "ok" => false,
                           "error_class" => "Net::SMTPAuthenticationError",
                           "error" => "535 5.7.8 Username and Password not accepted" }
  def unconfigured(role) = { "role" => role, "configured" => false, "ok" => false }

  it "is ok when both endpoints authenticate" do
    expect(described_class.classify([ok("primary"), ok("spare")])["verdict"]).to eq("ok")
  end

  # The whole point of probing the spare. A fallback nobody exercises is not a
  # fallback -- it is a hope. This must be loud even while the site is fine.
  it "is degraded when the spare is broken but the primary works" do
    result = described_class.classify([ok("primary"), broken("spare")])

    expect(result["verdict"]).to eq("degraded")
    expect(result["failures"].map { |f| f["role"] }).to eq(["spare"])
  end

  it "is down when the primary is broken, even if the spare works" do
    expect(described_class.classify([broken("primary"), ok("spare")])["verdict"]).to eq("down")
  end

  it "is down when both are broken" do
    expect(described_class.classify([broken("primary"), broken("spare")])["verdict"]).to eq("down")
  end

  # So the workflow can be merged and start running BEFORE the Fastmail app
  # password exists. A permanently-red probe teaches everyone to ignore it.
  it "does not fail merely because the spare is not configured yet" do
    result = described_class.classify([ok("primary"), unconfigured("spare")])

    expect(result["verdict"]).to eq("ok")
    expect(result["summary"]).to include("spare not configured")
  end

  it "still reports down when the primary fails and no spare is configured" do
    expect(described_class.classify([broken("primary"), unconfigured("spare")])["verdict"]).to eq("down")
  end

# The verdict JSON is embedded verbatim in a PUBLIC GitHub issue body by
# .github/workflows/smtp-probe.yml, so an address in an error message would
# be published, not merely logged. Truncation does not remove one: the
# realistic case below is well under MESSAGE_LIMIT.
it "redacts addresses out of an error message before it can be published" do
  redacted = described_class.redact(
    "553 5.7.1 <player@mezin.eu>: Sender address rejected: not owned by user encounter@gmail.com"
  )

  expect(redacted).not_to include("player@mezin.eu")
  expect(redacted).not_to include("encounter@gmail.com")
  # The diagnostic value must survive -- an unreadable log is its own defect.
  expect(redacted).to include("553 5.7.1")
  expect(redacted).to include("Sender address rejected")
end

  it "names the error class in the summary so the issue title is useful" do
    result = described_class.classify([broken("primary"), ok("spare")])

    expect(result["summary"]).to include("Net::SMTPAuthenticationError")
  end
end
