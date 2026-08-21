# Performance Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `workflow_dispatch` tool that measures the app under a named scenario and commits a durable, comparable record of the result.

**Architecture:** A new k6 `stampede` scenario; a pure-Ruby transformer from (k6 summary + host facts + run parameters) to one record JSON, unit-tested from fixtures; two small shell helpers that gather host facts and measure the generator's own network baseline; and a workflow wiring them together with either a GitHub runner or a throwaway Azure VM as the generator. It never resizes anything.

**Tech Stack:** GitHub Actions, k6 (JavaScript), Ruby, `az` CLI, `jq`.

**Spec:** `docs/superpowers/specs/2026-08-22-perf-probe-design.md` — read it first; this plan argues from it and does not restate its reasoning.

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Every command assumes `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` first.
- **Work in the worktree** `.claude/worktrees/perf-probe`, branch `design/perf-probe`. Other sessions share this checkout; never switch `master`.
- **Never edit any `features/**/*.feature` file.** The inherited contract is 228 scenarios / 2325 steps and must stay green.
- **Hash rockets** (`:key => value`) in Ruby; English identifiers and comments; user-facing strings via `t()` (nothing here should need a locale key — say so if you find otherwise).
- **The probe never resizes the host.** It records the shape it finds. No `az vm resize` anywhere in this work.
- **Every run measures its own network baseline before applying load**, and a failed baseline stops the run before any traffic.
- **Teardown of cohort and generator runs under `if: always()`.**
- **No credential may be committed.** The manifest holds live passwords; it never leaves the runner's ephemeral filesystem and is never an artifact.
- `generator.region` is `null` for a runner — honestly absent, not guessed.
- Follow `ops/vmscale/`'s established shape: **the shell gathers, the Ruby decides.** `policy.rb` is a pure function with no network, no shelling out and no clock, which is why it is testable from fixtures. `build_record.rb` must be the same.

---

### Task 1: The `stampede` scenario

**Files:**
- Modify: `load_test/main.js`
- Modify: `load_test/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `PHASE=stampede`, honouring `--env TEAMS` and `--env STAMPEDE_WINDOW` (default `30s`).

The spec's §8 calls this a prerequisite rather than a follow-up: the 2026-08-21 stampede measurement was produced *by accident*, by passing a single-plateau ladder that happened to ramp 0→120 inside the executor's 30-second stage. Nobody could reproduce it deliberately from the current inputs.

- [ ] **Step 1: Add the scenario**

Beside the existing `RAMP` and `HOLD` blocks in `load_test/main.js`:

```js
// Every team arriving at once, which is what a real encounter game does at the
// whistle. Measured 2026-08-21: 120 teams over 22 minutes gave p95 196ms; the
// same 120 arriving in 30 seconds gave p95 5860ms, with zero errors in both.
// The difference is 91 bcrypt logins landing together on one vCPU -- a cost no
// cache or index can reduce, and the sharpest risk this app has.
const STAMPEDE_WINDOW = __ENV.STAMPEDE_WINDOW || '30s';

const STAMPEDE = {
  executor: 'ramping-vus',
  startVUs: 0,
  stages: [
    { target: TEAMS, duration: STAMPEDE_WINDOW },
    { target: TEAMS, duration: '4m' },
  ],
  exec: 'session',
};
```

- [ ] **Step 2: Select it, and widen the oversubscription guard**

Change the scenario selection to a lookup so a typo in `PHASE` fails loudly rather than silently running the ramp:

```js
const SCENARIOS = { ramp: RAMP, hold: HOLD, stampede: STAMPEDE };
if (!SCENARIOS[PHASE]) {
  fail(`unknown PHASE ${JSON.stringify(PHASE)} -- expected one of ${Object.keys(SCENARIOS).join(', ')}`);
}
```

and use `scenarios: { [PHASE]: SCENARIOS[PHASE] }` in `options`.

The existing guard only checks `ramp`'s ladder. `stampede` oversubscribes the same way — `teamFor(vu)` assigns by modulo, so more VUs than teams means many sessions against one `GamePassing`. Extend it:

```js
if (PHASE === 'stampede' && TEAMS > manifest().teams.length) {
  fail(`TEAMS (${TEAMS}) exceeds the seeded cohort (${manifest().teams.length} teams). ` +
    `Seed at least ${TEAMS} teams, or lower TEAMS to match what's seeded.`);
}
```

- [ ] **Step 3: Keep the abort on, and say why**

`abortOnFail` is currently `PHASE === 'ramp'`. Change both thresholds to `PHASE !== 'hold'` and add:

```js
    // The stampede aborts like the ramp does. Both are exploratory runs against
    // production on a host shared with danted, the squid proxies and two APRS
    // forwarders; only `hold` is meant to run past a breach, because observing
    // what happens after the credit bank empties is its entire purpose.
```

- [ ] **Step 4: Verify the guard and the selector, without generating load**

```bash
export PATH="$HOME/.local/bin:$PATH"
cat > /tmp/tiny.json <<'JSON'
{"cohort_id":"lt-x","game_id":1,"run_id":1,"base_url":"http://127.0.0.1:9",
 "teams":[{"email":"a@loadtest.invalid","password":"p","team_id":1,"level_id":1}],
 "codes":{"1":["c1"]}}
JSON
k6 run --env MANIFEST=/tmp/tiny.json --env PHASE=stampede --env TEAMS=500 load_test/main.js 2>&1 | grep -i "exceeds the seeded"
k6 run --env MANIFEST=/tmp/tiny.json --env PHASE=nonsense --env TEAMS=1 load_test/main.js 2>&1 | grep -i "unknown PHASE"
```

Expected: the first prints the oversubscription refusal naming 500 and 1; the second prints the unknown-phase refusal. Both must fail before any request is attempted — the manifest points at a closed port, so any run that reaches HTTP is a run that got past the guard.

- [ ] **Step 5: Document it**

Add `stampede` to `load_test/README.md` beside `ramp` and `hold`: what it does, that `TEAMS` is a team count and not a rate, that `STAMPEDE_WINDOW` controls how compressed the arrival is, and the 196ms-versus-5860ms measurement as the reason it exists.

- [ ] **Step 6: Commit**

```bash
git add load_test/main.js load_test/README.md
git commit -m "Add a stampede scenario, the arrival pattern a real game night has"
```

---

### Task 2: `ops/perf/build_record.rb` — the pure transformer

**Files:**
- Create: `ops/perf/build_record.rb`
- Test: `spec/ops/perf_build_record_spec.rb`
- Create: `spec/fixtures/perf/k6-summary-aborted.json`, `spec/fixtures/perf/k6-summary-clean.json`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Perf::BuildRecord.call(summary:, host:, generator:, game:, run:, app:) -> Hash` matching the spec's §5 record, and a `#filename` giving `<ISO8601-compact>-<size-downcased>-game<N>.json`.

This mirrors `ops/vmscale/policy.rb`: a pure function, no network, no shelling out, no clock. That is what makes it testable from fixtures and is the only part of this subsystem a unit test can reach.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/ops/perf_build_record_spec.rb
require "spec_helper"
require_relative "../../ops/perf/build_record"

describe Perf::BuildRecord do
  let(:summary) { JSON.parse(File.read("spec/fixtures/perf/k6-summary-aborted.json")) }

  def call(overrides = {})
    described_class.call({
      :summary   => summary,
      :host      => { "size" => "Standard_B1ms", "vcpu" => 1, "ram_gib" => 2,
                      "credits_pct_start" => 96 },
      :generator => { "kind" => "vm", "region" => "westeurope",
                      "baseline_warm_ms" => 13.5 },
      :game      => { "id" => 4, "levels" => 71 },
      :run       => { "scenario" => "stampede", "teams" => 120,
                      "at" => "2026-08-21T20:15:00Z", "note" => "first stampede" },
      :app       => { "sha" => "276f55a" }
    }.merge(overrides))
  end

  it "carries every parameter that could explain a difference" do
    r = call
    expect(r["host"]["size"]).to eq("Standard_B1ms")
    expect(r["host"]["credits_pct_start"]).to eq(96)
    expect(r["generator"]["baseline_warm_ms"]).to eq(13.5)
    expect(r["game"]).to eq("id" => 4, "levels" => 71)
    expect(r["run"]).to include("scenario" => "stampede", "teams" => 120)
    expect(r["app"]["sha"]).to eq("276f55a")
    expect(r["note"]).to eq("first stampede")
  end

  it "extracts the latency percentiles k6 reports" do
    expect(call["result"]).to include("p50_ms", "p95_ms", "max_ms", "error_rate")
  end

  # The two aborted runs of 2026-08-21 are the most valuable measurements taken
  # so far. A transformer that only handled clean runs would have discarded them.
  it "records an aborted run as a result, naming what tripped" do
    r = call
    expect(r["result"]["outcome"]).to eq("aborted")
    expect(r["result"]["abort_reason"]).to eq("http_req_duration")
  end

  it "records a clean run as completed, with no abort reason" do
    clean = JSON.parse(File.read("spec/fixtures/perf/k6-summary-clean.json"))
    r = call(:summary => clean)
    expect(r["result"]["outcome"]).to eq("completed")
    expect(r["result"]["abort_reason"]).to be_nil
  end

  # A runner's region is not reliably knowable. A field that is sometimes a fact
  # and sometimes a guess is worse than one that is honestly absent.
  it "leaves a runner's region null rather than guessing" do
    r = call(:generator => { "kind" => "runner", "region" => nil,
                             "baseline_warm_ms" => 94.0 })
    expect(r["generator"]).to include("kind" => "runner", "region" => nil)
  end

  it "names the file so a directory listing sorts chronologically and reads legibly" do
    expect(described_class.new(**{
      :summary => summary,
      :host => { "size" => "Standard_B1ms" }, :generator => {},
      :game => { "id" => 4 }, :run => { "at" => "2026-08-21T20:15:00Z" }, :app => {}
    }).filename).to eq("2026-08-21T2015Z-standard_b1ms-game4.json")
  end
end
```

- [ ] **Step 2: Build the two fixtures**

Generate them rather than hand-writing: run k6 with `--summary-export`, once against a deliberately unreachable host with a threshold that trips (aborted) and once with a trivially satisfiable threshold (clean), then trim each to the keys the transformer reads. Record in the spec file's header comment which command produced each. A hand-invented fixture is a guess about k6's output shape; a trimmed real one is evidence.

- [ ] **Step 3: Run it and confirm it fails**

Run: `bundle exec rspec spec/ops/perf_build_record_spec.rb`
Expected: FAIL — `cannot load such file -- ops/perf/build_record`.

Note this uses `spec_helper`, not `rails_helper`, for the same reason `spec/ops/vmscale_policy_spec.rb` does: a pure function needs no database.

- [ ] **Step 4: Implement**

```ruby
# ops/perf/build_record.rb
#
# A pure function from one k6 summary plus the facts surrounding a run to the
# record that outlives it. No network, no shelling out, no clock -- `at` arrives
# in the input -- which is what makes it testable from fixtures, exactly as
# ops/vmscale/policy.rb is.
#
# The reason this exists at all: on 2026-08-21 the same 120 teams on the same
# host gave p95 196ms arriving over 22 minutes and p95 5860ms arriving over 30
# seconds. A record holding only the number would have been misleading within a
# month. Everything that could explain a difference is captured here, at the
# moment of the run, because none of it can be reconstructed afterwards.
require "json"

module Perf
  class BuildRecord
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
      { "at"        => @run["at"],
        "note"      => @run["note"],
        "host"      => @host,
        "generator" => @generator,
        "game"      => @game,
        "run"       => @run.slice("scenario", "teams"),
        "app"       => @app,
        "result"    => result }
    end

    # Sorts chronologically in a plain listing and still says what it is at a
    # glance -- the two things a directory of accumulated results needs.
    def filename
      stamp = @run["at"].to_s.gsub(/[-:]/, "").sub(/\A(\d{8})T(\d{4}).*\z/) { "#{$1}T#{$2}Z" }
      iso   = @run["at"].to_s[0, 10]
      "#{iso}T#{stamp[9, 4]}Z-#{@host["size"].to_s.downcase}-game#{@game["id"]}.json"
    end

    private

    def result
      d = @summary.dig("metrics", "http_req_duration", "values") || {}
      f = @summary.dig("metrics", "http_req_failed", "values") || {}
      { "p50_ms"       => ms(d["med"]),
        "p95_ms"       => ms(d["p(95)"]),
        "max_ms"       => ms(d["max"]),
        "error_rate"   => f["rate"],
        "outcome"      => outcome,
        "abort_reason" => abort_reason }
    end

    def ms(value)
      value && value.round(1)
    end

    # k6 marks a threshold that tripped; the abort is the one carrying
    # abortOnFail, so the first crossed threshold names what stopped the run.
    def crossed
      (@summary["metrics"] || {}).select { |_, m| m.dig("thresholds")&.values&.any? { |t| t["ok"] == false } }
    end

    def outcome
      crossed.any? ? "aborted" : "completed"
    end

    def abort_reason
      crossed.keys.first
    end
  end
end
```

- [ ] **Step 5: Run it and confirm it passes**

Run: `bundle exec rspec spec/ops/perf_build_record_spec.rb`
Expected: PASS, 6 examples, 0 failures.

If `filename` is awkward against a real ISO timestamp, simplify it — but keep the property the test asserts: chronological sort order and a legible host/game in the name.

- [ ] **Step 6: Commit**

```bash
git add ops/perf/build_record.rb spec/ops/perf_build_record_spec.rb spec/fixtures/perf/
git commit -m "Turn a k6 summary and its surrounding facts into a durable record"
```

---

### Task 3: `ops/perf/baseline.sh` and `ops/perf/host_facts.sh`

**Files:**
- Create: `ops/perf/baseline.sh`, `ops/perf/host_facts.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `baseline.sh <url>` printing `{"baseline_warm_ms": 13.5}`; `host_facts.sh` printing `{"size":"Standard_B1ms","vcpu":1,"ram_gib":2,"credits_pct_start":96}`.

- [ ] **Step 1: Write `baseline.sh`**

```bash
#!/usr/bin/env bash
# Measures what this generator's network costs, before any load is applied.
#
# The generator is selectable, so results from a GitHub runner and from a
# westeurope VM are not the same measurement: on 2026-08-21 a warm request cost
# 94ms from a laptop in Georgia and 13.5ms from a VM in the app's own region,
# against an application time of 16-17ms. Recording this per run is what lets
# those two results be compared at all.
#
# WARM connections only -- k6 reuses connections, so a cold-handshake number
# would overstate what the run actually pays. curl's second request on one
# invocation reuses the connection, which is why the URL is passed twice and
# only the second timing is taken.
set -euo pipefail
URL="${1:?usage: baseline.sh <url>}"

samples=()
for _ in 1 2 3 4 5; do
  t=$(curl -fsS -o /dev/null -o /dev/null \
        -w '%{time_total}\n' "$URL" "$URL" 2>/dev/null | tail -1) || {
    echo "baseline measurement failed against $URL" >&2; exit 1; }
  samples+=("$t")
done

printf '%s\n' "${samples[@]}" | sort -n | awk '
  { a[NR] = $1 }
  END {
    if (NR == 0) { print "no samples" > "/dev/stderr"; exit 1 }
    printf "{\"baseline_warm_ms\": %.1f}\n", a[int(NR/2)+1] * 1000
  }'
```

`chmod +x` it. A failed measurement exits non-zero, which the workflow treats as fatal: the spec is explicit that a result with no baseline cannot be compared to anything and is not worth the traffic.

- [ ] **Step 2: Write `host_facts.sh`**

```bash
#!/usr/bin/env bash
# The host shape and its CPU credit balance, at the moment of the run.
#
# credits_pct_start looks like noise and is not: this is a burstable VM, and the
# same load against a full credit bank and a drained one gives different
# answers. A k6 summary knows nothing about it, so without this field two runs a
# month apart could differ by host shape, by game, by code -- or purely by how
# idle the machine happened to be beforehand.
#
# ops/vmscale/gather.sh already reads both from Azure for the scaling policy;
# this is the same two queries, kept separate because gather.sh returns a much
# larger document shaped for policy.rb rather than for a record.
set -euo pipefail
RG="${RG:-MEZINEU}"
VM="${VM:-web}"

ID="$(az vm show -g "$RG" -n "$VM" --query id -o tsv)"
SIZE="$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv)"

read -r VCPU RAM_MB <<<"$(az vm list-sizes -l "$(az vm show -g "$RG" -n "$VM" --query location -o tsv)" \
  --query "[?name=='${SIZE}'].[numberOfCores,memoryInMb]" -o tsv)"

CREDITS="$(az monitor metrics list --resource "$ID" \
  --metric "CPU Credits Remaining" --aggregation Minimum \
  --interval PT5M --offset 15m \
  --query "value[0].timeseries[0].data[?minimum!=null] | [-1].minimum" -o tsv 2>/dev/null || echo "")"

jq -n --arg size "$SIZE" --argjson vcpu "${VCPU:-null}" \
      --argjson ram "$(awk -v m="${RAM_MB:-0}" 'BEGIN{printf "%d", m/1024}')" \
      --arg credits "${CREDITS:-}" \
  '{ size: $size, vcpu: $vcpu, ram_gib: $ram,
     credits_pct_start: (if $credits == "" then null else ($credits | tonumber) end) }'
```

**`credits_pct_start` is `null` when Azure has no datapoint**, not zero. The spec is explicit that absent data must never read as reassuring — a missing credit reading is unknown, and zero would mean "exhausted", which is the opposite conclusion.

- [ ] **Step 3: Verify both against reality**

```bash
./ops/perf/baseline.sh https://game.mezin.eu/up
RG=MEZINEU VM=web ./ops/perf/host_facts.sh
```

Expected: a JSON object from each, `size` reading `Standard_B1ms`, `vcpu` 1, `ram_gib` 2, and a plausible `credits_pct_start`. Both are read-only — `baseline.sh` issues ten trivial GETs and `host_facts.sh` only queries Azure. Paste both outputs into your report.

Also confirm `baseline.sh` exits non-zero against an unreachable URL: `./ops/perf/baseline.sh http://127.0.0.1:9/up; echo "exit=$?"` must print a non-zero exit and an error on stderr.

- [ ] **Step 4: Commit**

```bash
chmod +x ops/perf/baseline.sh ops/perf/host_facts.sh
git add ops/perf/
git commit -m "Gather what a performance record needs: a baseline and a host shape"
```

---

### Task 4: The workflow

**Files:**
- Create: `.github/workflows/perf-probe.yml`

**Interfaces:**
- Consumes: `load_test/main.js` (Task 1), `ops/perf/build_record.rb` (Task 2), `ops/perf/baseline.sh` and `ops/perf/host_facts.sh` (Task 3).
- Produces: records under `docs/perf/results/`, and a `k6-summary` artifact.

Read `.github/workflows/deploy.yml` before writing this. Its OIDC login, its pinned `webfactory/ssh-agent`, its hard-coded `known_hosts` line (deliberately not `ssh-keyscan` — the comment explains why), and its just-in-time NSG rule created and deleted **in the same job** are all patterns to reuse verbatim rather than reinvent.

- [ ] **Step 1: Inputs and permissions**

```yaml
name: Performance probe
on:
  workflow_dispatch:
    inputs:
      source_game:  { description: "Source game id to clone", type: string, required: true }
      teams:        { description: "Teams to seed", type: string, default: "120" }
      scenario:     { description: "Which question", type: choice, default: stampede,
                      options: [stampede, ramp, hold] }
      generator:    { description: "Where load comes from", type: choice, default: runner,
                      options: [runner, vm] }
      note:         { description: "Free text, e.g. 'before the Postgres tuning'", type: string, default: "" }

permissions:
  contents: write      # commits the record
  id-token: write      # OIDC to Azure

concurrency:
  group: perf-probe
  cancel-in-progress: false
```

`concurrency` matters: two probes at once would seed two cohorts, and `Seeder`'s advisory lock would refuse the second mid-workflow rather than politely queueing it.

- [ ] **Step 2: Seed, with teardown registered immediately**

Generate the cohort id in the workflow so teardown always knows it, and export it before seeding so an `always()` step can use it even if seeding fails halfway:

```yaml
      - name: Generate the cohort id
        run: echo "COHORT=lt-$(date -u +%Y-%m-%dT%H%M)-probe" >> "$GITHUB_ENV"
```

Then seed over SSH, capturing the manifest to the runner's filesystem:

```yaml
      - name: Seed the cohort
        run: |
          set -euo pipefail
          ssh mezin "C=\$(docker ps --format '{{.Names}}' | grep encounter-engine-web)
            docker exec -e LOAD_TEST_COHORT=$COHORT -e LOAD_TEST_CONFIRM=$COHORT \
              -e LOAD_TEST_BASE_URL=https://${{ vars.APP_HOST || 'game.mezin.eu' }} \
              \"\$C\" bin/rails 'load_test:seed[${{ inputs.source_game }},${{ inputs.teams }}]'
            docker exec \"\$C\" cat /tmp/$COHORT.json" > manifest.json
          chmod 600 manifest.json
          ruby -rjson -e 'm=JSON.parse(File.read("manifest.json")); \
            abort("manifest has no teams") if m["teams"].to_a.empty?; \
            puts "seeded #{m["teams"].size} teams, #{m["codes"].size} levels"'
```

`LOAD_TEST_BASE_URL` is passed explicitly even though the seeder would derive it
from `APP_HOST` — belt and braces on the defect that produced a
localhost-pointing manifest on 2026-08-21.

**`manifest.json` never becomes an artifact and is never echoed.** It holds a
live password for every seeded captain and every answer code in the source game.

- [ ] **Step 3: Gather the host facts**

```yaml
      - name: Gather the host shape and credit balance
        env: { RG: MEZINEU, VM: web }
        run: ./ops/perf/host_facts.sh | tee host.json
```

This runs after the Azure OIDC login and needs no SSH — it queries Azure, not
the host. It must come **before** load is applied: `credits_pct_start` means the
balance the run started with, and reading it afterwards would record the balance
the run itself produced.

- [ ] **Step 4: Measure the baseline, and stop if it fails**

```yaml
      - name: Measure this generator's baseline
        run: ./ops/perf/baseline.sh "https://${{ vars.APP_HOST || 'game.mezin.eu' }}/up" | tee baseline.json
```

No `continue-on-error`. A failed baseline must stop the run before load, per the spec.

- [ ] **Step 5: Run k6, on whichever generator was chosen**

Two steps guarded by `if: inputs.generator == 'runner'` and `if: inputs.generator == 'vm'`. Both must end with the same artefact on the runner: `summary.json`, written by `k6 run --summary-export summary.json`.

The `vm` path calls `./load_test/provision.sh create`, `scp`s the manifest and `load_test/` up, runs k6 there, and `scp`s `summary.json` back. `provision.sh` resolves the caller's public IP for its NSG rule, which on a runner is the runner's IP, so it needs no change.

**Neither path may fail the job on a k6 non-zero exit.** An aborted run is a result the record must capture — use `continue-on-error: true` on the k6 step specifically, and nowhere else.

- [ ] **Step 6: Build and commit the record**

```yaml
      - name: Build the record
        run: |
          ruby -e '
            require "json"
            require_relative "ops/perf/build_record"
            rec = Perf::BuildRecord.new(
              :summary   => JSON.parse(File.read("summary.json")),
              :host      => JSON.parse(File.read("host.json")),
              :generator => JSON.parse(File.read("baseline.json"))
                              .merge("kind" => ENV["GEN"], "region" => ENV["GEN_REGION"].to_s.empty? ? nil : ENV["GEN_REGION"]),
              :game      => JSON.parse(File.read("game.json")),
              :run       => { "at" => ENV["AT"], "note" => ENV["NOTE"],
                              "scenario" => ENV["SCENARIO"], "teams" => ENV["TEAMS"].to_i },
              :app       => { "sha" => ENV["GITHUB_SHA"][0, 7] })
            path = File.join("docs/perf/results", rec.filename)
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, JSON.pretty_generate(rec.to_h) + "\n")
            puts path
          '
```

`GEN_REGION` is `westeurope` for the vm path and empty for the runner — the record must carry `null`, not `"unknown"`.

**If `summary.json` does not exist**, k6 died before writing one — a crash, a
guard refusal, an unreachable host. Write a record anyway with
`result.outcome = "errored"` and the other result fields `null`, because a run
that failed to produce numbers is still a fact about that host and that game on
that date, and the spec is explicit that a failed run is data. Guard the build
step with a check for the file rather than letting `JSON.parse` raise.

`game.json` comes from a `rails runner` over SSH during seeding: `{"id": N, "levels": M}`.

Commit it with a message naming the scenario, teams and host, and push.

- [ ] **Step 7: Tear down everything, always**

```yaml
      - name: Tear down the cohort
        if: always() && env.COHORT != ''
        run: |
          set -euo pipefail
          ssh mezin "C=\$(docker ps --format '{{.Names}}' | grep encounter-engine-web)
            docker exec -e LOAD_TEST_CONFIRM=$COHORT \"\$C\" \
              bin/rails 'load_test:teardown[$COHORT]'
            docker exec \"\$C\" bin/rails load_test:status" | tee teardown.log
          grep -q ':cohort_id=>nil' teardown.log || {
            echo "::error::TEARDOWN DID NOT COMPLETE. Recover with:"
            echo "::error::  ssh mezin \"docker exec -e LOAD_TEST_CONFIRM=$COHORT <container> bin/rails 'load_test:teardown[$COHORT]'\""
            exit 1; }
      - name: Destroy the generator
        if: always() && inputs.generator == 'vm'
        run: ./load_test/provision.sh destroy
      - name: Close the NSG hole
        if: always()
        run: # az network nsg rule delete, as deploy.yml does
```

If teardown fails, **fail the job loudly and print the recovery command with the cohort id**. A silent failure leaves hundreds of accounts in production.

- [ ] **Step 8: Upload the k6 summary as an artifact**

`if: always()`, uploading `summary.json` only. **Never the manifest** — it holds a live password for every seeded captain.

- [ ] **Step 9: Validate the workflow parses**

```bash
gh workflow list 2>/dev/null | head -3
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/perf-probe.yml')); print('yaml ok')"
```

You cannot run the workflow from here — it needs the repository's secrets and a dispatch. Say plainly in your report that it is unexecuted, and list what a first dispatch will exercise for the first time.

- [ ] **Step 10: Commit**

```bash
git add .github/workflows/perf-probe.yml
git commit -m "Add the performance probe workflow"
```

---

### Task 5: Documentation and the gate

**Files:**
- Modify: `docs/runbooks/load-test.md`
- Create: `docs/perf/README.md`

- [ ] **Step 1: Explain the record directory**

`docs/perf/README.md`: what a record is, what each field means, why `credits_pct_start` and `baseline_warm_ms` exist (a burstable host and a selectable generator), and the worked example — 120 teams at p95 196ms and p95 5860ms on the same box — so the next reader understands immediately why comparing bare numbers is unsafe.

- [ ] **Step 2: Point the runbook at the probe**

A short section in `docs/runbooks/load-test.md`: the manual procedure remains for exploratory work; the probe is for producing a comparable record. Note it never resizes.

- [ ] **Step 3: Run the gates**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bin/rails zeitwerk:check
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: RSpec 0 failures (master was 2705 examples, 0 failures, 6 pending; this plan adds ~6). Cucumber **228 scenarios / 2325 steps**, unmoved — nothing here touches a feature file. `zeitwerk:check` clean.

Note `ops/` is outside the autoload path, so `build_record.rb` is `require_relative`'d rather than autoloaded — the same arrangement `ops/vmscale/policy.rb` uses.

- [ ] **Step 4: Commit and push**

```bash
git add docs/
git commit -m "Document the performance record and point the runbook at the probe"
git push -u origin design/perf-probe
```

---

## Open questions this plan does not settle

From the spec's §9, and deliberately left for the owner:

1. **Whether the workflow needs an `environment:` approval gate** as `vm-scale.yml`'s apply job has. This plan ships without one: seeding is reversible and takes seconds, and `workflow_dispatch` already requires write access. It does create hundreds of production rows, so the default deserves an explicit yes or no rather than silence.
2. **Whether `hold` is worth supporting** until a run approaches a real ceiling. At 10% CPU the credit bank cannot drain, so the phase has nothing to observe. It is kept as an input because it costs nothing to keep.
3. **How accumulated records get read.** A directory of JSON is greppable and diffable, which is enough to start. Whether it wants a summary table is a question for when there are twenty records, not now.
