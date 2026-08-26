# frozen_string_literal: true

require "spec_helper"
require_relative "../../ops/smtp/roles"

# resolve is a pure function: no network, no clock, no ENV. Same reasoning as
# spec/ops/vmscale_policy_spec.rb -- the workflow gathers, the Ruby decides, and
# only the deciding is tested here.
RSpec.describe SMTPRoles do
  ENDPOINTS = {
    "gmail"    => { "host" => "smtp.gmail.com",    "port" => 587 },
    "fastmail" => { "host" => "smtp.fastmail.com", "port" => 587 }
  }.freeze

  it "puts the named vendor live and the other on standby" do
    result = described_class.resolve(:role => "gmail", :endpoints => ENDPOINTS)

    expect(result["live"]["vendor"]).to eq("gmail")
    expect(result["live"]["host"]).to eq("smtp.gmail.com")
    expect(result["standby"]["vendor"]).to eq("fastmail")
    expect(result["standby"]["host"]).to eq("smtp.fastmail.com")
  end

  # The whole point of the design: the same map with a different pointer swaps
  # both roles, and nothing else anywhere has to change.
  it "swaps both roles when the pointer moves" do
    result = described_class.resolve(:role => "fastmail", :endpoints => ENDPOINTS)

    expect(result["live"]["vendor"]).to eq("fastmail")
    expect(result["standby"]["vendor"]).to eq("gmail")
  end

  it "carries the port through" do
    result = described_class.resolve(:role => "gmail", :endpoints => ENDPOINTS)

    expect(result["live"]["port"]).to eq(587)
    expect(result["standby"]["port"]).to eq(587)
  end

  # Loudly, not silently. A typo in MAIL_ROLE must stop the deploy, never
  # resolve to an empty host and ship mail configured to talk to nowhere.
  it "refuses an unknown role" do
    expect { described_class.resolve(:role => "gnail", :endpoints => ENDPOINTS) }
      .to raise_error(ArgumentError, /gnail/)
  end

  it "refuses an empty role" do
    expect { described_class.resolve(:role => "", :endpoints => ENDPOINTS) }
      .to raise_error(ArgumentError)
  end

  it "refuses a map that cannot name a standby" do
    expect { described_class.resolve(:role => "gmail", :endpoints => { "gmail" => { "host" => "x" } }) }
      .to raise_error(ArgumentError, /standby/)
  end

  it "refuses a vendor entry with no host" do
    broken = { "gmail" => { "port" => 587 }, "fastmail" => { "host" => "smtp.fastmail.com" } }

    expect { described_class.resolve(:role => "gmail", :endpoints => broken) }
      .to raise_error(ArgumentError, /host/)
  end

  # The shipped map is the one production actually uses, so assert on it rather
  # than only on fixtures -- a fixture-only spec would pass with the real file
  # empty or malformed.
  it "resolves against the shipped endpoints file" do
    endpoints = YAML.safe_load_file(
      File.expand_path("../../#{described_class::ENDPOINTS_PATH}", __dir__)
    )

    expect(endpoints.keys).to contain_exactly("gmail", "fastmail")
    expect(described_class.resolve(:role => "gmail", :endpoints => endpoints)["live"]["host"])
      .to eq("smtp.gmail.com")
  end
end
