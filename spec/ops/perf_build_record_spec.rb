# Fixtures are REAL k6 output, not hand-written. Generated 2026-08-22 with:
#
#   k6 run --env LIMIT=60000 --summary-export clean.json   fx.js   # threshold satisfied
#   k6 run --env LIMIT=1     --summary-export aborted.json fx.js   # threshold impossible
#
# where fx.js issued three GETs against https://game.mezin.eu/up with a
# `p(95)<$LIMIT` threshold, then trimmed to the metrics this transformer reads.
#
# Generating them mattered: the shape is not what one would guess. Metrics are
# FLAT (`.med`, `.["p(95)"]`) with no `.values` nesting; `http_req_failed`
# carries `value`, not `rate`; and a threshold entry is `true` when it was
# CROSSED, which reads backwards until you see it.
require "spec_helper"
require_relative "../../ops/perf/build_record"

describe Perf::BuildRecord do
  let(:aborted) { JSON.parse(File.read("spec/fixtures/perf/k6-summary-aborted.json")) }
  let(:clean)   { JSON.parse(File.read("spec/fixtures/perf/k6-summary-clean.json")) }

  def call(overrides = {})
    described_class.call(**{
      :summary   => aborted,
      :host      => { "size" => "Standard_B1ms", "vcpu" => 1, "ram_gib" => 2,
                      "credits_pct_start" => 96 },
      :generator => { "kind" => "vm", "region" => "westeurope",
                      "baseline_warm_ms" => 13.5 },
      :game      => { "id" => 4, "levels" => 71 },
      :run       => { "scenario" => "stampede", "teams" => 120,
                      "stampede_window" => "30s",
                      "at" => "2026-08-21T20:15:00Z", "note" => "first stampede" },
      :app       => { "sha" => "276f55a" }
    }.merge(overrides))
  end

  it "carries every parameter that could explain a difference" do
    r = call
    expect(r["host"]).to include("size" => "Standard_B1ms", "credits_pct_start" => 96)
    expect(r["generator"]["baseline_warm_ms"]).to eq(13.5)
    expect(r["game"]).to eq("id" => 4, "levels" => 71)
    expect(r["run"]).to eq("scenario" => "stampede", "teams" => 120,
                           "stampede_window" => "30s")
    expect(r["app"]["sha"]).to eq("276f55a")
    expect(r["note"]).to eq("first stampede")
    expect(r["at"]).to eq("2026-08-21T20:15:00Z")
  end

  # Without this, `"stampede_window": null` on a stampede record is ambiguous
  # in the one way that matters: it could mean the run genuinely had no window,
  # or that the record predates the field existing. Only a reader who happens to
  # know the field was added on 2026-08-27 can tell, and a directory whose
  # meaning depends on remembering its own history is the thing this whole
  # format exists to avoid.
  it "stamps the version of the format each record was written by" do
    expect(call["schema"]).to eq(Perf::BuildRecord::SCHEMA)
  end

  # Pinned to a literal deliberately. `eq(SCHEMA)` above would pass forever
  # while the constant drifted; this example is what makes bumping the version
  # a decision rather than an accident, and its failure is the prompt to write
  # down what changed in docs/perf/README.md.
  it "is at version 2 -- version 1 predates run.stampede_window" do
    expect(Perf::BuildRecord::SCHEMA).to eq(2)
  end

  # The arrival window is the parameter this file's own header is about: the
  # 196ms-vs-5860ms pair it cites as the reason the record exists differs by
  # nothing except how long the same 120 teams took to arrive. It was the one
  # thing `run` did not carry, so two records a month apart could disagree by
  # 30x with no field explaining why.
  it "carries the arrival window, which is what the 196ms/5860ms pair differs by" do
    fast = call(:run => { "scenario" => "stampede", "teams" => 120,
                          "stampede_window" => "22m",
                          "at" => "2026-08-21T20:15:00Z", "note" => "" })
    slow = call(:run => { "scenario" => "stampede", "teams" => 120,
                          "stampede_window" => "30s",
                          "at" => "2026-08-21T20:15:00Z", "note" => "" })
    expect(fast["run"]["stampede_window"]).to eq("22m")
    expect(slow["run"]["stampede_window"]).to eq("30s")
    expect(fast["run"].reject { |k, _| k == "stampede_window" })
      .to eq(slow["run"].reject { |k, _| k == "stampede_window" })
  end

  # Recording "30s" against a ramp would assert a parameter that had no effect
  # on it -- STAMPEDE_WINDOW is read by the stampede scenario alone. The key
  # stays present so every record has the same shape and diffs cleanly; null
  # says "not applicable" rather than "unmeasured".
  it "records no arrival window for a scenario that has none" do
    r = call(:run => { "scenario" => "ramp", "teams" => 120,
                       "stampede_window" => "30s",
                       "at" => "2026-08-21T20:15:00Z", "note" => "" })
    expect(r["run"]).to have_key("stampede_window")
    expect(r["run"]["stampede_window"]).to be_nil
  end

  it "reads the latency percentiles out of k6's flat metric shape" do
    r = call["result"]
    expect(r["p50_ms"]).to eq(75.5)
    expect(r["p95_ms"]).to eq(76.2)
    expect(r["max_ms"]).to eq(76.3)
    expect(r["error_rate"]).to eq(0)
  end

  # The two aborted runs of 2026-08-21 are the most valuable measurements taken
  # so far. A transformer that only handled clean runs would have discarded them.
  it "records an aborted run as a result, naming what tripped" do
    r = call["result"]
    expect(r["outcome"]).to eq("aborted")
    expect(r["abort_reason"]).to eq("http_req_duration")
  end

  it "records a clean run as completed, with no abort reason" do
    r = call(:summary => clean)["result"]
    expect(r["outcome"]).to eq("completed")
    expect(r["abort_reason"]).to be_nil
  end

  # k6 died before writing a summary -- a crash, a guard refusal, an unreachable
  # host. That is still a fact about this host and this game on this date.
  it "records a run that produced no summary at all as errored" do
    r = call(:summary => nil)["result"]
    expect(r["outcome"]).to eq("errored")
    expect(r["p95_ms"]).to be_nil
    expect(r["error_rate"]).to be_nil
  end

  # A runner's region is not reliably knowable. A field that is sometimes a fact
  # and sometimes a guess is worse than one that is honestly absent.
  it "leaves a runner's region null rather than guessing" do
    r = call(:generator => { "kind" => "runner", "region" => nil,
                             "baseline_warm_ms" => 94.0 })
    expect(r["generator"]).to include("kind" => "runner", "region" => nil)
  end

  it "names the file so a listing sorts chronologically and reads legibly" do
    expect(described_class.new(
      **{ :summary => aborted, :host => { "size" => "Standard_B1ms" },
      :generator => {}, :game => { "id" => 4 },
      :run => { "at" => "2026-08-21T20:15:00Z" }, :app => {} }
    ).filename).to eq("2026-08-21T2015Z-standard_b1ms-game4.json")
  end
end
