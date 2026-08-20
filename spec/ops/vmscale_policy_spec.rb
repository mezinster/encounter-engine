# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../ops/vmscale/policy"

RSpec.describe VMScale::Policy do
  # The one fixture on disk is real gather.sh output against the production VM.
  # Every synthetic case mutates a deep copy of it rather than living as its own
  # hand-written JSON file, so a schema change breaks all of them at once
  # instead of leaving stale fixtures that quietly stop resembling Azure.
  REAL_INPUT = JSON.parse(
    File.read(File.expand_path("../fixtures/vmscale/input-quiet-2026-08-20.json", __dir__))
  ).freeze

  # Deep copy, then let the caller mutate it.
  def build(input = REAL_INPUT)
    copy = Marshal.load(Marshal.dump(input))
    yield copy if block_given?
    copy
  end

  describe "the real production baseline" do
    subject(:result) { described_class.decide(build) }

    it "holds" do
      expect(result["verdict"]).to eq("hold")
    end

    it "proposes nothing" do
      expect(result["target"]).to be_nil
    end

    it "reports the current size" do
      expect(result["current"]).to eq("Standard_B1ms")
    end

    it "always gives a reason, even when quiet" do
      # A log that records only exceptions cannot answer the question
      # "was it quiet, or was the poller broken?"
      expect(result["reasons"]).not_to be_empty
    end

    it "carries the computed aggregates as evidence" do
      expect(result["evidence"]).to include(
        "window_points", "cpu_busy_points", "memory_min_mb", "credits_min", "quiet_days"
      )
    end
  end

  # Drive every point of a series to a fixed value, in both the 3-hour window
  # and the 14-day hourly rollup, so a case cannot accidentally stay quiet in
  # one window while breaching in the other.
  #
  # Also clears last_resize_utc. Task 7 adds a 48-hour cooldown that suppresses
  # proposals after a recent resize; the captured fixture's value is far older
  # than that today, but a fixture recaptured just after a VM write would make
  # every synthetic scale_up case below return `hold` for an unrelated reason,
  # which reads exactly like a broken threshold.
  def flood(input, series, key, value)
    input["metrics"][series].each { |p| p[key] = value }
    input["metrics"]["hourly_14d"][series].each { |p| p[key] = value }
    input["last_resize_utc"] = nil
  end

  describe "credit depletion" do
    # 22% of the 288 ceiling, well under the 30% floor.
    let(:draining) do
      build do |i|
        flood(i, "cpu_credits_remaining", "min", 63.4)
        i["metrics"]["credits_max_7d"] = 288.0
      end
    end

    it "proposes the next rung up" do
      result = described_class.decide(draining)
      expect(result["verdict"]).to eq("scale_up")
      expect(result["target"]).to eq("Standard_B2s")
    end

    it "names the numbers in the reason" do
      expect(described_class.decide(draining)["reasons"].join)
        .to match(/cpu credits: min 63\.4 below 86\.4/)
    end

    it "does not fire while the bank is nearly full" do
      # The measured production reality: CPU peaks at 99% and costs 3 credits.
      expect(described_class.decide(build)["verdict"]).to eq("hold")
    end

    # Mutation check: the threshold must be load-bearing. A value just inside
    # the floor must hold, and a value just outside it must fire.
    it "turns over exactly at 30% of the 7-day maximum" do
      just_inside = build do |i|
        flood(i, "cpu_credits_remaining", "min", 86.5)
        i["metrics"]["credits_max_7d"] = 288.0
      end
      just_outside = build do |i|
        flood(i, "cpu_credits_remaining", "min", 86.3)
        i["metrics"]["credits_max_7d"] = 288.0
      end

      expect(described_class.decide(just_inside)["verdict"]).to eq("hold")
      expect(described_class.decide(just_outside)["verdict"]).to eq("scale_up")
    end
  end
end
