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

  describe "the memory floor" do
    let(:starved) { build { |i| flood(i, "available_memory_bytes", "min", 180 * 1024 * 1024) } }

    it "proposes the next rung up" do
      result = described_class.decide(starved)
      expect(result["verdict"]).to eq("scale_up")
      expect(result["target"]).to eq("Standard_B2s")
    end

    it "reports megabytes rather than bytes" do
      expect(described_class.decide(starved)["reasons"].join)
        .to match(/available memory: min 180 MB below the 200 MB floor/)
    end

    it "does not fire at the measured production worst case" do
      # 472 MB was the lowest observed in the seven days to 2026-08-20.
      breathing = build { |i| flood(i, "available_memory_bytes", "min", 472 * 1024 * 1024) }
      expect(described_class.decide(breathing)["verdict"]).to eq("hold")
    end

    it "turns over exactly at 200 MB" do
      just_inside  = build { |i| flood(i, "available_memory_bytes", "min", 200 * 1024 * 1024) }
      just_outside = build { |i| flood(i, "available_memory_bytes", "min", 200 * 1024 * 1024 - 1) }

      expect(described_class.decide(just_inside)["verdict"]).to eq("hold")
      expect(described_class.decide(just_outside)["verdict"]).to eq("scale_up")
    end

    it "never infers a breach from an absent reading" do
      # gather.sh drops points Azure had no data for. A dropped point must not
      # read as zero bytes free, which would be the most severe breach possible.
      blank = build { |i| i["metrics"]["available_memory_bytes"].each { |p| p.delete("min") } }
      expect(described_class.decide(blank)["reasons"].join).not_to match(/available memory/)
    end
  end

  describe "sustained cpu" do
    # Set the first N points busy and the rest idle, in the 3-hour window only.
    #
    # Clears last_resize_utc for the same reason `flood` does: Task 7's cooldown
    # would otherwise suppress these proposals if the fixture were ever
    # recaptured shortly after a VM write.
    def with_busy_points(count)
      build do |i|
        i["last_resize_utc"] = nil
        i["metrics"]["cpu_percent"].each_with_index do |point, index|
          point["avg"] = index < count ? 95.0 : 3.0
        end
      end
    end

    it "fires once twelve of the window's points are busy" do
      expect(described_class.decide(with_busy_points(12))["verdict"]).to eq("scale_up")
    end

    it "holds at eleven" do
      expect(described_class.decide(with_busy_points(11))["verdict"]).to eq("hold")
    end

    it "counts the busy points in the reason" do
      expect(described_class.decide(with_busy_points(20))["reasons"].join)
        .to match(/sustained cpu: 20 of \d+ points above 80%/)
    end

    it "ignores a brief spike, however severe" do
      # Three five-minute points at 99% is what a deploy looks like.
      expect(described_class.decide(with_busy_points(3))["verdict"]).to eq("hold")
    end
  end

  describe "the budget ceiling" do
    # On B2s and breaching. The next rung, B2ms at $70.08 + $7.50 baseline,
    # is $77.58 against a $45 ceiling -- and past the subscription's credit,
    # which disables rather than degrades when it runs out.
    let(:cornered) do
      build do |i|
        i["current_size"] = "Standard_B2s"
        flood(i, "cpu_credits_remaining", "min", 40.0)
      end
    end

    it "does not propose an unaffordable rung" do
      expect(described_class.decide(cornered)["verdict"]).to eq("at_budget_ceiling")
    end

    it "proposes no target at all" do
      expect(described_class.decide(cornered)["target"]).to be_nil
    end

    it "keeps the breach in the reasons, and names the money" do
      reasons = described_class.decide(cornered)["reasons"].join
      expect(reasons).to match(/cpu credits/)
      expect(reasons).to match(/Standard_B2ms would cost \$77\.58\/mo, over the \$45\.00 ceiling/)
    end

    it "still proposes the rung when it is affordable" do
      affordable = build do |i|
        i["current_size"] = "Standard_B2s"
        i["budget_ceiling_usd"] = 90
        flood(i, "cpu_credits_remaining", "min", 40.0)
      end
      expect(described_class.decide(affordable)["target"]).to eq("Standard_B2ms")
    end

    it "treats a rung costing exactly the ceiling as affordable" do
      # The engine refuses a rung that BREACHES the ceiling, and a cost equal to
      # it does not breach it -- so the comparison is `>`, not `>=`. Pinned
      # because that choice is otherwise invisible: mutating it to `>=` passes
      # every other example in this file.
      #
      # The ceiling is written as the sum rather than the literal 77.58 so that
      # it is bit-identical to what monthly_total computes. The same two Floats
      # added in the same order cannot disagree; a decimal literal could.
      exact = build do |i|
        i["current_size"] = "Standard_B2s"
        i["budget_ceiling_usd"] = 70.08 + 7.5
        flood(i, "cpu_credits_remaining", "min", 40.0)
      end
      expect(described_class.decide(exact)["target"]).to eq("Standard_B2ms")
    end

    it "moves one rung even when the breach is dramatic" do
      dire = build do |i|
        flood(i, "cpu_credits_remaining", "min", 0.0)
        flood(i, "available_memory_bytes", "min", 1024)
      end
      # From B1ms that is B2s, never a jump straight to B2ms.
      expect(described_class.decide(dire)["target"]).to eq("Standard_B2s")
    end

    it "holds at the top of the ladder" do
      topped = build do |i|
        i["current_size"] = "Standard_B2ms"
        flood(i, "cpu_credits_remaining", "min", 40.0)
      end
      result = described_class.decide(topped)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join).to match(/is the top of the ladder/)
    end
  end

  describe "suppressors" do
    let(:breaching) { build { |i| flood(i, "cpu_credits_remaining", "min", 40.0) } }

    it "holds within 48 hours of the last resize" do
      recent = build do |i|
        flood(i, "cpu_credits_remaining", "min", 40.0)
        i["now_utc"]         = "2026-08-20T19:00:00Z"
        i["last_resize_utc"] = "2026-08-20T13:00:00Z"
      end
      result = described_class.decide(recent)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join).to match(/cooldown: 42\.0h of 48h remaining/)
    end

    it "proposes again once the cooldown has expired" do
      stale = build do |i|
        flood(i, "cpu_credits_remaining", "min", 40.0)
        i["now_utc"]         = "2026-08-20T19:00:00Z"
        i["last_resize_utc"] = "2026-08-18T13:00:00Z"
      end
      expect(described_class.decide(stale)["verdict"]).to eq("scale_up")
    end

    it "has no cooldown when the VM has never been resized" do
      never = build do |i|
        flood(i, "cpu_credits_remaining", "min", 40.0)
        i["last_resize_utc"] = nil
      end
      expect(described_class.decide(never)["verdict"]).to eq("scale_up")
    end

    it "says so on every verdict when the activity log cannot be read" do
      # Degrading silently is the failure this repository is bitten by most
      # often. A cooldown that has stopped applying must be as loud as one
      # that fires.
      blind = build { |i| i["activity_log_readable"] = false }
      expect(described_class.decide(blind)["reasons"].join)
        .to match(/activity log unreadable: the cooldown is not in force/)
    end

    it "will not propose a size the cluster does not offer" do
      stranded = build do |i|
        flood(i, "cpu_credits_remaining", "min", 40.0)
        i["resize_options"] = ["Standard_B1ms"]
      end
      result = described_class.decide(stranded)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join)
        .to match(/Standard_B2s is not offered by the cluster this VM sits on/)
    end

    it "never infers a breach from a short window" do
      thin = build { |i| i["metrics"]["cpu_percent"] = i["metrics"]["cpu_percent"].first(10) }
      result = described_class.decide(thin)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join)
        .to match(/insufficient data: cpu_percent returned 10 of 36 expected points/)
    end

    it "never infers a breach from a missing credit ceiling" do
      unanchored = build { |i| i["metrics"]["credits_max_7d"] = 0 }
      result = described_class.decide(unanchored)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join).to match(/credits_max_7d is missing or zero/)
    end

    it "checks the cooldown before the data, so a fresh resize is never masked" do
      both = build do |i|
        i["metrics"]["cpu_percent"] = i["metrics"]["cpu_percent"].first(10)
        i["now_utc"]         = "2026-08-20T19:00:00Z"
        i["last_resize_utc"] = "2026-08-20T13:00:00Z"
      end
      expect(described_class.decide(both)["reasons"].join).to match(/cooldown/)
    end

    it "suppresses rather than proposes when the last resize is dated in the future" do
      # Clock skew between the runner and the Activity Log. The likeliest cause
      # is a resize that just landed, so this must not fail open into proposing
      # a reboot minutes after one.
      skewed = build do |i|
        flood(i, "cpu_credits_remaining", "min", 40.0)
        i["now_utc"]         = "2026-08-20T19:00:00Z"
        i["last_resize_utc"] = "2026-08-20T21:00:00Z"
      end
      result = described_class.decide(skewed)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join).to match(/cooldown: 48\.0h of 48h remaining/)
    end

    it "lifts the cooldown at exactly forty-eight hours" do
      # The boundary is `>=`, so 48.0h elapsed is expired, not expiring.
      exact = build do |i|
        flood(i, "cpu_credits_remaining", "min", 40.0)
        i["now_utc"]         = "2026-08-20T19:00:00Z"
        i["last_resize_utc"] = "2026-08-18T19:00:00Z"
      end
      expect(described_class.decide(exact)["verdict"]).to eq("scale_up")
    end
  end
end
