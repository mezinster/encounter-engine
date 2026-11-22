#!/usr/bin/env ruby
# frozen_string_literal: true

# Pure decision function for the host's OS-patching health report.
#
# Input on stdin: {"now_utc": "...", "report": <the JSON written by
# ops/host/encounter-engine-patch-health, or null if it could not be read>}.
# Output on stdout: a verdict. Exit status 0 means ok, 1 means unhealthy.
# With --public, the verdict carries finding codes and fixed sentences only
# (see PUBLIC_TEXT); that is the form for anywhere world-readable.
#
# No network, no shelling out, and no clock: `now_utc` arrives in the input,
# so this is testable from fixtures alone. It is the same shape as
# ops/vmscale/policy.rb, for the same reason.
#
# The rule this file exists to enforce: ABSENT DATA IS NEVER READ AS
# REASSURING. A missing report, an old report, a report from stale package
# lists: each of these is a finding, not a pass. The failure this replaces
# (2026-10-25 to 2026-11-21) was four weeks of a green systemd unit doing
# nothing.

require "json"
require "time"

module PatchHealth
  module Policy
    # The host writes daily around 08:10 and the workflow reads at 09:37, so a
    # healthy report is about 1.5 hours old. 30 hours allows for timer jitter
    # and a late run, and still alerts on the first fully missed day.
    REPORT_MAX_AGE_HOURS = 30
    # apt-daily refreshes the package lists twice a day. Three days without
    # a successful refresh means it is failing, and an empty pending list
    # computed from those lists proves nothing.
    APT_UPDATE_MAX_AGE_DAYS = 3
    # unattended-upgrades runs daily, so a security update still pending
    # after three days means it is being skipped or is failing. Three rather
    # than one, so a run that hits a busy dpkg lock can retry without paging
    # anyone.
    SECURITY_PENDING_MAX_DAYS = 3
    # Installed but not running is not patched: a new kernel or libc does
    # nothing until a reboot. A week leaves time to pick a quiet moment, since
    # a reboot here is downtime for the only instance.
    REBOOT_PENDING_MAX_DAYS = 7
    # These are what unattended-upgrades logs when it gives up without
    # installing anything. The first is the exact 2026-10-25 symptom, logged
    # while the run exited 0.
    UU_FAILURE_PATTERNS = [
      /Lock could not be acquired/,
      /dpkg was interrupted/,
      /\bERROR\b/
    ].freeze

    # What a finding may say in PUBLIC: the issue body and the Actions log,
    # both world-readable because this repository is public. These are fixed
    # strings, deliberately with no interpolation. The `detail` of a finding
    # names packages, versions, how long each has gone unpatched, and log
    # lines, which together are a reconnaissance list for this server. That
    # stays on the host: the report is in the journal of
    # encounter-engine-patch-health.service, so `--public` is the only mode
    # the workflow uses. spec/ops/patchhealth_policy_spec.rb fails if report
    # content ever leaks into this output.
    PUBLIC_TEXT = {
      "no_report" => "No readable report in blob storage: the host, its timer, or the upload is broken.",
      "stale_report" => "The newest report is older than the limit: the host has stopped reporting.",
      "dpkg_broken" => "dpkg --audit reports unfinished packages; apt cannot install anything until they are fixed.",
      "apt_update_unknown" => "There is no record of a successful apt-get update.",
      "apt_update_stale" => "The package lists have not refreshed successfully for days.",
      "security_updates_stuck" => "Security updates have been pending longer than the limit.",
      "reboot_pending" => "A reboot has been required for longer than the limit.",
      "unattended_upgrades_unknown" => "No unattended-upgrades run was found in its log.",
      "unattended_upgrades_failing" => "The last unattended-upgrades run reported a failure."
    }.freeze

    module_function

    # The verdict with every finding reduced to its code and fixed public
    # sentence. Built from scratch, not filtered from the full verdict, so
    # a field added to findings later cannot leak through here by default.
    def public_view(result)
      {
        "verdict" => result["verdict"],
        "summary" => result["findings"].map { |f| f["code"] }.join(", ").then { |c| c.empty? ? "OS patching is healthy" : c },
        "findings" => result["findings"].map { |f| { "code" => f["code"], "text" => PUBLIC_TEXT.fetch(f["code"]) } }
      }
    end

    def decide(input)
      now = Time.iso8601(input.fetch("now_utc"))
      report = input["report"]

      return verdict([finding("no_report", "no readable patch-health report in blob storage; the host may be down or the timer broken")]) unless report.is_a?(Hash)

      generated = parse_time(report["generated_at"])
      unless generated
        return verdict([finding("no_report", "the report has no readable generated_at")])
      end

      findings = []
      age_h = (now - generated) / 3600.0
      if age_h > REPORT_MAX_AGE_HOURS
        findings << finding("stale_report", "the newest report is #{age_h.round(1)} hours old (limit #{REPORT_MAX_AGE_HOURS}); the host has stopped reporting")
      end

      audit = report["dpkg_audit"].to_s.strip
      unless audit.empty?
        findings << finding("dpkg_broken", "dpkg --audit reports unfinished packages, and every apt run will fail until they are fixed: #{audit.lines.first(3).join(' ').strip}")
      end

      apt_ok = parse_time(report["apt_update_success_at"])
      if apt_ok.nil?
        findings << finding("apt_update_unknown", "no record of a successful apt-get update; the pending list cannot be trusted")
      elsif (days = (generated - apt_ok) / 86_400.0) > APT_UPDATE_MAX_AGE_DAYS
        findings << finding("apt_update_stale", "the last successful apt-get update was #{days.round(1)} days before the report (limit #{APT_UPDATE_MAX_AGE_DAYS})")
      end

      stuck = Array(report["security_pending"]).select do |p|
        seen = parse_time(p["first_seen_at"])
        seen.nil? || (generated - seen) / 86_400.0 > SECURITY_PENDING_MAX_DAYS
      end
      unless stuck.empty?
        names = stuck.map { |p| p["package"] }.first(8).join(", ")
        findings << finding("security_updates_stuck", "#{stuck.size} security update(s) pending for over #{SECURITY_PENDING_MAX_DAYS} days: #{names}")
      end

      reboot = parse_time(report["reboot_required_since"])
      if reboot && (days = (generated - reboot) / 86_400.0) > REBOOT_PENDING_MAX_DAYS
        findings << finding("reboot_pending", "a reboot has been required for #{days.round(1)} days (limit #{REBOOT_PENDING_MAX_DAYS}); installed kernel or libc fixes are not running yet")
      end

      uu = report["last_unattended_upgrades_run"]
      if uu.nil?
        findings << finding("unattended_upgrades_unknown", "no unattended-upgrades run found in its log")
      elsif (hit = UU_FAILURE_PATTERNS.find { |re| uu.match?(re) })
        line = uu.lines.find { |l| l.match?(hit) }.to_s.strip
        findings << finding("unattended_upgrades_failing", "the last unattended-upgrades run failed: #{line}")
      end

      verdict(findings)
    end

    def finding(code, detail)
      { "code" => code, "detail" => detail }
    end

    def verdict(findings)
      if findings.empty?
        { "verdict" => "ok", "summary" => "OS patching is healthy", "findings" => [] }
      else
        { "verdict" => "unhealthy", "summary" => findings.map { |f| f["code"] }.join(", "), "findings" => findings }
      end
    end

    def parse_time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  result = PatchHealth::Policy.decide(JSON.parse($stdin.read))
  puts JSON.pretty_generate(ARGV.include?("--public") ? PatchHealth::Policy.public_view(result) : result)
  exit(result["verdict"] == "ok" ? 0 : 1)
end
