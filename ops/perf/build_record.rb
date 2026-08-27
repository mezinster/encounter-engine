# A pure function from one k6 summary plus the facts surrounding a run to the
# record that outlives it. No network, no shelling out, no clock -- `at` arrives
# in the input -- which is what makes it testable from fixtures, exactly as
# ops/vmscale/policy.rb is. The shell gathers; the Ruby decides.
#
# Why it exists: on 2026-08-21 the same 120 teams on the same host gave p95
# 196ms arriving over 22 minutes and p95 5860ms arriving over 30 seconds, with
# zero errors in both. A record holding only the number would have been
# misleading within a month. Everything that could explain a difference is
# captured here, at the moment of the run, because none of it can be
# reconstructed afterwards.
require "json"

module Perf
  class BuildRecord
    # The version of the RECORD FORMAT, not of this file. Bump it when a field
    # is added, removed, or changes meaning; leave it alone for a refactor.
    #
    # It exists because absence is ambiguous and the ambiguity is silent.
    # `"stampede_window": null` on a stampede record could mean the run had no
    # window or that the record was written before the field existed, and only
    # a reader who knows the field arrived on 2026-08-27 can tell -- a
    # directory whose meaning depends on remembering its own history is exactly
    # what this format exists to avoid. With a version, that reading is
    # mechanical: no `schema` key at all is version 1.
    #
    #   1  the original shape. `run` carries scenario and teams only. Every
    #      version-1 stampede ran a 30s arrival window, because nothing could
    #      set STAMPEDE_WINDOW -- an inference from the code of the day, which
    #      is precisely the kind of inference a later reader should not have to
    #      make unaided, and the reason this constant now exists.
    #   2  adds run.stampede_window (2026-08-27), null for ramp and hold, which
    #      pace themselves.
    #   3  (2026-08-28) `result.abort_reason` becomes `result.thresholds_crossed`,
    #      a list; `result.outcome` stops claiming a run was cut short, which it
    #      could never observe; `run.duration_s` records how long k6 actually
    #      ran; `host` gains the credit readings taken AFTER the run. Version 2
    #      derived outcome as `crossed.any? ? "aborted" : "completed"`, so the
    #      40-minute hold run of 2026-08-27 -- which ran to its planned end and
    #      passed both latency thresholds -- was filed as "aborted" next to a
    #      stampede that really was killed at 32 seconds. Reading a version-2
    #      record: "aborted" means "some threshold was crossed" and nothing more.
    SCHEMA = 3

    def self.call(**kwargs)
      new(**kwargs).to_h
    end

    def initialize(summary:, host:, generator:, game:, run:, app:)
      @summary   = summary
      @host      = host
      @generator = generator
      @game      = game
      @run       = run
      @app       = app
    end

    def to_h
      { "schema"    => SCHEMA,
        "at"        => @run["at"],
        "note"      => @run["note"],
        "host"      => @host,
        "generator" => @generator,
        "game"      => @game,
        "run"       => @run.slice("scenario", "teams").merge(
                         "stampede_window" => stampede_window,
                         "duration_s"      => @run["duration_s"]),
        "app"       => @app,
        "result"    => result }
    end

    # Sorts chronologically in a plain `ls` and still says what it is at a
    # glance -- the two things a directory of accumulated results needs.
    def filename
      at   = @run["at"].to_s
      date = at[0, 10]
      hhmm = at[11, 5].to_s.delete(":")
      "#{date}T#{hhmm}Z-#{@host["size"].to_s.downcase}-game#{@game["id"]}.json"
    end

    private

    # k6's --summary-export shape is not what you would guess, and each of these
    # was confirmed against real output rather than assumed (see the spec's
    # header for how the fixtures were generated):
    #
    #   * metrics are FLAT -- `.med`, `.["p(95)"]`, `.max`. There is no `values`
    #     nesting, unlike the newer handleSummary structure.
    #   * http_req_failed carries `value` (the rate), not `rate`. Its `passes`
    #     and `fails` counts read backwards from their names and are not used.
    #   * a threshold entry is `true` when it was CROSSED. `{"p(95)<1": true}`
    #     came from the impossible threshold; `{"p(95)<60000": false}` from the
    #     trivially satisfiable one.
    def result
      return errored if @summary.nil?

      d = @summary.dig("metrics", "http_req_duration") || {}
      f = @summary.dig("metrics", "http_req_failed") || {}

      { "p50_ms"             => ms(d["med"]),
        "p95_ms"             => ms(d["p(95)"]),
        "max_ms"             => ms(d["max"]),
        "error_rate"         => f["value"],
        "outcome"            => "completed",
        "thresholds_crossed" => crossed.keys }
    end

    # k6 wrote no summary: it died before finishing -- a crash, a startup guard
    # refusing, an unreachable host. Still a fact about this host and this game
    # on this date, and the design is explicit that a failed run is data.
    def errored
      { "p50_ms" => nil, "p95_ms" => nil, "max_ms" => nil, "error_rate" => nil,
        "outcome" => "errored", "thresholds_crossed" => nil }
    end

    # `outcome` answers one question and no longer pretends to answer two: did
    # this run produce a measurement at all. It cannot honestly say more. This
    # class is a pure function of a k6 summary, and a summary is written both by
    # a run that finished and by one `abortOnFail` killed mid-flight -- nothing
    # in it distinguishes them. Version 2 guessed, by treating any crossed
    # threshold as an abort, and the guess was wrong for every `hold` run ever
    # taken: load_test/main.js sets `abortOnFail: PHASE != "hold"` on the two
    # thresholds that carry it and gives `checks` none at all, so no threshold
    # can cut a hold run short and "aborted" was unreachable as a description of
    # one.
    #
    # `run.duration_s` is what answers the question instead, and it is a
    # measurement rather than an inference: 32 seconds against a 30s-window
    # stampede says it was killed; 2430 against a 40-minute hold says it was
    # not. Encoding main.js's abort policy here was the alternative, and it
    # would have put that policy in two files that can drift apart silently --
    # which is the failure this whole format exists to prevent.
    def crossed
      (@summary["metrics"] || {}).select do |_name, metric|
        metric.is_a?(Hash) && metric["thresholds"].is_a?(Hash) &&
          metric["thresholds"].values.any? { |breached| breached == true }
      end
    end

    def ms(value)
      value && value.round(1)
    end

    # The header above cites 196ms against 5860ms, same host, same game, same
    # 120 teams -- differing by nothing but how long those teams took to
    # arrive. That window was the one parameter `run` did not carry, so the
    # two records the docstring is about would have been indistinguishable in
    # this directory apart from the number they disagree by.
    #
    # nil for anything but a stampede, because STAMPEDE_WINDOW is read by that
    # scenario alone (load_test/main.js) -- recording "30s" against a ramp
    # would assert a parameter that had no effect on it. The key is emitted
    # either way so every record keeps the same shape and diffs cleanly; here
    # null means "not applicable", not "unmeasured".
    def stampede_window
      return nil unless @run["scenario"].to_s == "stampede"

      value = @run["stampede_window"].to_s
      value.empty? ? nil : value
    end
  end
end
