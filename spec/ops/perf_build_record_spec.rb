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
#
# The third fixture is not synthetic either: it is the summary k6 exported from
# the 40-minute `hold` run of 2026-08-27, downloaded from that workflow run's
# own artifact (run 33109290689). It is here because it is the shape the first
# two cannot express -- THREE metrics carrying thresholds, exactly one crossed,
# and that one being `checks`, which load_test/main.js gives no `abortOnFail`.
# A hand-written fixture would have been a guess about the case that mattered
# most.
#
# The fourth and fifth were generated the same way as the first two, on
# 2026-08-28 with the same k6 v0.52.0 the probe installs, by a scenario that
# flips `exec.vu.tags.phase` from `warmup` to `steady` after its first request
# and declares thresholds on both the plain metric and the submetric:
#
#   k6 run --summary-export steady.json         --env LIMIT=60000 fx.js
#   k6 run --summary-export steady-crossed.json --env LIMIT=1     fx.js
#
# They pin two things worth knowing before reading the transformer. The
# submetric key is a literal `http_req_duration{phase:steady}` -- a flat string
# in `metrics`, not a nested structure. And in `steady-phase` the whole-run p95
# is 105.2 ms against the steady phase's 82.7 ms, from nothing but each VU's
# first request paying a TLS handshake: the warm-up really does move the number,
# at three requests, which is the effect this version exists to remove from a
# 40-minute run.
require "spec_helper"
require_relative "../../ops/perf/build_record"

describe Perf::BuildRecord do
  let(:aborted) { JSON.parse(File.read("spec/fixtures/perf/k6-summary-aborted.json")) }
  let(:clean)   { JSON.parse(File.read("spec/fixtures/perf/k6-summary-clean.json")) }
  let(:hold)    { JSON.parse(File.read("spec/fixtures/perf/k6-summary-hold-checks.json")) }
  let(:steady)  { JSON.parse(File.read("spec/fixtures/perf/k6-summary-steady-phase.json")) }
  let(:steady_crossed) do
    JSON.parse(File.read("spec/fixtures/perf/k6-summary-steady-crossed.json"))
  end

  def call(overrides = {})
    described_class.call(**{
      :summary   => aborted,
      :host      => { "size" => "Standard_B1ms", "vcpu" => 1, "ram_gib" => 2,
                      "credits_pct_start" => 96 },
      :generator => { "kind" => "vm", "region" => "westeurope",
                      "baseline_warm_ms" => 13.5 },
      :game      => { "id" => 4, "levels" => 71 },
      :run       => { "scenario" => "stampede", "teams" => 120,
                      "stampede_window" => "30s", "duration_s" => 32,
                      "at" => "2026-08-21T20:15:00Z", "note" => "first stampede" },
      :app       => { "sha" => "276f55a" }
    }.merge(overrides))
  end

  # The real parameters of the run the third fixture was exported from: 120
  # teams held for k6's full 40 minutes, which it reported as 40m30.0s.
  let(:hold_run) do
    { "scenario" => "hold", "teams" => 120, "stampede_window" => nil,
      "duration_s" => 2430, "at" => "2026-08-27T19:37:19Z", "note" => "" }
  end

  it "carries every parameter that could explain a difference" do
    r = call
    expect(r["host"]).to include("size" => "Standard_B1ms", "credits_pct_start" => 96)
    expect(r["generator"]["baseline_warm_ms"]).to eq(13.5)
    expect(r["game"]).to eq("id" => 4, "levels" => 71)
    expect(r["run"]).to eq("scenario" => "stampede", "teams" => 120,
                           "stampede_window" => "30s", "duration_s" => 32)
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
  it "is at version 4 -- version 3 measured the warm-up along with the run" do
    expect(Perf::BuildRecord::SCHEMA).to eq(4)
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
  it "names every threshold a run crossed, not merely the first" do
    expect(call["result"]["thresholds_crossed"]).to eq(["http_req_duration"])
  end

  it "records a clean run as completed, with nothing crossed" do
    r = call(:summary => clean)["result"]
    expect(r["outcome"]).to eq("completed")
    expect(r["thresholds_crossed"]).to eq([])
  end

  # The defect version 3 exists to fix. `outcome` was
  # `crossed.any? ? "aborted" : "completed"`, so ANY breached threshold read as
  # a run that had been cut short. For `hold` no threshold can cut a run short:
  # load_test/main.js sets `abortOnFail: PHASE !== "hold"` on the two that carry
  # it and gives `checks` none at all. So the 40-minute run of 2026-08-27 ran to
  # its planned end, passed both latency thresholds, and was filed as "aborted"
  # -- a word no reader could have known was unreachable for that scenario.
  it "does not call a run aborted on the strength of a crossed threshold" do
    r = call(:summary => hold, :run => hold_run)["result"]
    expect(r["outcome"]).to eq("completed")
    expect(r["thresholds_crossed"]).to eq(["checks"])
  end

  # The other half of the same point, and the half the old shape destroyed: the
  # two thresholds that WOULD have aborted a stampede were both satisfied, with
  # a five-fold margin on latency. A reader of `"aborted"` / `"checks"` had no
  # way to recover that.
  it "keeps the satisfied thresholds out of the crossed list" do
    r = call(:summary => hold, :run => hold_run)["result"]
    expect(r["p95_ms"]).to eq(371.5)
    expect(r["thresholds_crossed"]).not_to include("http_req_duration")
    expect(r["thresholds_crossed"]).not_to include("http_req_failed")
  end

  # k6 died before writing a summary -- a crash, a guard refusal, an unreachable
  # host. That is still a fact about this host and this game on this date.
  it "records a run that produced no summary at all as errored" do
    r = call(:summary => nil)["result"]
    expect(r["outcome"]).to eq("errored")
    expect(r["p95_ms"]).to be_nil
    expect(r["error_rate"]).to be_nil
  end

  # nil, not []. An empty list asserts "nothing was crossed", which is a
  # measurement; a run that wrote no summary produced none. Absent data is never
  # read as reassuring -- the rule ops/perf/host_facts.sh already applies to the
  # credit fields, here applied to thresholds.
  it "leaves the crossed list null when there was no measurement to cross" do
    expect(call(:summary => nil)["result"]["thresholds_crossed"]).to be_nil
  end

  # The fact that separates "cut short at 32 seconds" from "ran its planned 40
  # minutes and breached at the end" -- which is exactly the pair the old
  # `outcome` conflated. Establishing it for the 2026-08-27 hold run meant
  # reading the workflow log by hand, and Actions logs age out.
  it "records how long the run actually lasted" do
    expect(call(:run => hold_run)["run"]["duration_s"]).to eq(2430)
  end

  it "leaves the duration null rather than guessing when it was not measured" do
    r = call(:run => { "scenario" => "hold", "teams" => 120,
                       "at" => "2026-08-27T19:37:19Z", "note" => "" })
    expect(r["run"]).to have_key("duration_s")
    expect(r["run"]["duration_s"]).to be_nil
  end

  # `hold` exists to ask what an hour of play does to a burstable VM's credit
  # bank, and version 2 recorded only the balance the run STARTED with -- so the
  # scenario could not answer its own question. Two readings after, not one: a
  # bank that dipped and recovered reads as untouched at the end, and the dip is
  # the interesting half.
  it "carries the credit standing after the run, not only before it" do
    r = call(:host => { "size" => "Standard_B1ms", "vcpu" => 1, "ram_gib" => 2,
                        "cpu_credits_remaining_start" => 288.0,
                        "cpu_credits_remaining_end" => 288.0,
                        "cpu_credits_min_during" => 287.5,
                        "cpu_credits_max_7d" => 288.0 })
    expect(r["host"]).to include("cpu_credits_remaining_start" => 288.0,
                                 "cpu_credits_remaining_end" => 288.0,
                                 "cpu_credits_min_during" => 287.5)
  end

  # A runner's region is not reliably knowable. A field that is sometimes a fact
  # and sometimes a guess is worse than one that is honestly absent.
  it "leaves a runner's region null rather than guessing" do
    r = call(:generator => { "kind" => "runner", "region" => nil,
                             "baseline_warm_ms" => 94.0 })
    expect(r["generator"]).to include("kind" => "runner", "region" => nil)
  end

  # `hold` starts every VU in the same instant, so its first minute is an arrival
  # burst sharper than any stampede this project has run -- and version 3
  # averaged that burst into a summary meant to describe steady play. The run of
  # 2026-08-27 reported p95 371.5 ms with a p90 of 49 ms, LOWER than either
  # healthy stampede: a clean body with a startup-shaped tail. The harness now
  # tags requests taken after each VU has logged in, and the measurement follows
  # the tag.
  it "measures the steady phase when the run recorded one" do
    r = call(:summary => steady)["result"]
    expect(r["measured_from"]).to eq("http_req_duration{phase:steady}")
    expect(r["p50_ms"]).to eq(77.1)
    expect(r["p95_ms"]).to eq(82.7)
  end

  # Beside it, never instead of it. Excluding the warm-up is a measurement
  # decision, and a record that quietly reported the better number would be
  # hiding exactly the kind of parameter this whole format exists to carry --
  # the difference here is 82.7 ms against 105.2 ms, from three requests.
  it "keeps the whole run beside the steady phase, so nothing is hidden" do
    r = call(:summary => steady)["result"]
    expect(r["whole_run"]).to include("p50_ms" => 77.4, "p95_ms" => 105.2,
                                      "max_ms" => 105.2)
  end

  # nil, not a copy of the top-level figures. `whole_run` present asserts that
  # something WAS excluded; on a run with no warm-up to exclude, repeating the
  # same numbers underneath would invent a distinction that was never drawn.
  it "reports no separate whole-run figure when nothing was excluded" do
    r = call(:summary => clean)["result"]
    expect(r["measured_from"]).to eq("http_req_duration")
    expect(r["whole_run"]).to be_nil
  end

  # The builder must not learn which scenarios have a warm-up. That is the
  # mistake version 3 was written to undo -- `outcome` encoded main.js's abort
  # policy and went stale when main.js changed underneath it. So the rule is
  # about the DATA: measure the steady submetric when the summary contains one,
  # whatever scenario produced it.
  it "decides from the summary, not from the scenario name" do
    r = call(:summary => steady,
             :run => { "scenario" => "stampede", "teams" => 120,
                       "stampede_window" => "30s", "duration_s" => 32,
                       "at" => "2026-08-21T20:15:00Z", "note" => "" })["result"]
    expect(r["measured_from"]).to eq("http_req_duration{phase:steady}")
  end

  it "names a crossed threshold by the submetric it was declared on" do
    r = call(:summary => steady_crossed)["result"]
    expect(r["thresholds_crossed"]).to eq(["http_req_duration{phase:steady}"])
  end

  # have_key, not just nil. Every record keeps the same shape so the directory
  # diffs cleanly -- the same reason `stampede_window` is emitted for scenarios
  # that have none. A key that vanishes on errored runs would make `jq` reading
  # across the directory hand back nothing and look like a value.
  it "reports no measurement source for a run that produced no summary" do
    r = call(:summary => nil)["result"]
    expect(r).to have_key("measured_from")
    expect(r).to have_key("whole_run")
    expect(r["measured_from"]).to be_nil
  end

  it "names the file so a listing sorts chronologically and reads legibly" do
    expect(described_class.new(
      **{ :summary => aborted, :host => { "size" => "Standard_B1ms" },
      :generator => {}, :game => { "id" => 4 },
      :run => { "at" => "2026-08-21T20:15:00Z" }, :app => {} }
    ).filename).to eq("2026-08-21T2015Z-standard_b1ms-game4.json")
  end
end
