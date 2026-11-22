# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require_relative "../../ops/patchhealth/policy"

RSpec.describe PatchHealth::Policy do
  # Real output of ops/host/encounter-engine-patch-health on the production VM,
  # taken right after patching was repaired. Every unhealthy case mutates a
  # copy of it, so a change to the report's shape breaks all of them together
  # instead of leaving hand-written fixtures that no longer match the host.
  REAL_REPORT = JSON.parse(
    File.read(File.expand_path("../fixtures/patchhealth/report-healthy-2026-11-22.json", __dir__))
  ).freeze

  # 09:37 the next morning: when the workflow would read it.
  NEXT_MORNING = "2026-11-23T09:37:00Z"

  def report
    copy = Marshal.load(Marshal.dump(REAL_REPORT))
    yield copy if block_given?
    copy
  end

  def decide(rep, now: NEXT_MORNING)
    described_class.decide("now_utc" => now, "report" => rep)
  end

  def codes(result)
    result["findings"].map { |f| f["code"] }
  end

  it "passes the real healthy report" do
    expect(decide(report)).to include("verdict" => "ok", "findings" => [])
  end

  describe "absent data is never reassuring" do
    it "flags a missing report" do
      expect(codes(decide(nil))).to eq(["no_report"])
    end

    it "flags a report with no readable timestamp" do
      expect(codes(decide(report { |r| r["generated_at"] = "yesterday" }))).to eq(["no_report"])
    end

    it "flags a report older than the limit, and only that" do
      result = decide(report, now: "2026-11-23T21:11:00Z") # 30h + 30s after generation
      expect(codes(result)).to eq(["stale_report"])
    end

    it "accepts a report just inside the limit" do
      expect(decide(report, now: "2026-11-23T21:10:00Z")["verdict"]).to eq("ok")
    end

    it "flags missing apt-update evidence rather than trusting an empty pending list" do
      expect(codes(decide(report { |r| r["apt_update_success_at"] = nil }))).to eq(["apt_update_unknown"])
    end

    it "flags a log with no unattended-upgrades run in it" do
      expect(codes(decide(report { |r| r["last_unattended_upgrades_run"] = nil }))).to eq(["unattended_upgrades_unknown"])
    end
  end

  # The actual 2026-10-25 failure, as this report would have described it a
  # few days in: a half-installed package, u-u giving up on the lock, and
  # security updates piling up while the apt lists kept refreshing fine.
  it "catches the 2026-10-25 stuck-dpkg incident on every axis it touched" do
    broken = report do |r|
      r["dpkg_audit"] = "The following packages are only half configured, probably due to problems\n" \
                        "configuring them the first time.  The configuration should be retried using\n" \
                        "dpkg --configure <package> or the configure menu option in dselect:\n mdatp"
      r["last_unattended_upgrades_run"] =
        "2026-11-22 06:04:11,087 INFO Starting unattended upgrades script\n" \
        "2026-11-22 06:04:11,301 INFO Lock could not be acquired (another package manager running?)"
      r["security_pending"] = [
        { "package" => "libc6", "version" => "2.35-0ubuntu3.12", "first_seen_at" => "2026-11-01T08:10:00Z" },
        { "package" => "openssl", "version" => "3.0.2-0ubuntu1.21", "first_seen_at" => "2026-11-21T08:10:00Z" }
      ]
    end
    result = decide(broken)

    expect(result["verdict"]).to eq("unhealthy")
    expect(codes(result)).to contain_exactly("dpkg_broken", "unattended_upgrades_failing", "security_updates_stuck")
    stuck = result["findings"].find { |f| f["code"] == "security_updates_stuck" }["detail"]
    expect(stuck).to include("1 security update(s)", "libc6")
    expect(stuck).not_to include("openssl") # one day old: not stuck yet
  end

  it "flags package lists that stopped refreshing" do
    expect(codes(decide(report { |r| r["apt_update_success_at"] = "2026-11-19T09:00:00Z" }))).to eq(["apt_update_stale"])
  end

  it "treats a pending update with no first-seen time as stuck, not fresh" do
    rep = report { |r| r["security_pending"] = [{ "package" => "x", "version" => "1" }] }
    expect(codes(decide(rep))).to eq(["security_updates_stuck"])
  end

  it "flags a reboot pending for over a week, but not a fresh one" do
    expect(codes(decide(report { |r| r["reboot_required_since"] = "2026-11-14T00:00:00Z" }))).to eq(["reboot_pending"])
    expect(decide(report { |r| r["reboot_required_since"] = "2026-11-20T00:00:00Z" })["verdict"]).to eq("ok")
  end

  describe "as a command" do
    let(:script) { File.expand_path("../../ops/patchhealth/policy.rb", __dir__) }

    it "exits 0 on ok and 1 on unhealthy, printing the verdict" do
      out, status = Open3.capture2("ruby", script, stdin_data: JSON.generate("now_utc" => NEXT_MORNING, "report" => REAL_REPORT))
      expect([status.exitstatus, JSON.parse(out)["verdict"]]).to eq([0, "ok"])

      out, status = Open3.capture2("ruby", script, stdin_data: JSON.generate("now_utc" => NEXT_MORNING, "report" => nil))
      expect([status.exitstatus, JSON.parse(out)["verdict"]]).to eq([1, "unhealthy"])
    end
  end
end
