# VM Scaling Track 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch the production Azure VM's load, propose a resize when it nears a real ceiling, and let a human approve it — nothing resizes without that approval.

**Architecture:** A bash script gathers every fact from Azure and prints one JSON document. A pure Ruby function reads that document and prints a verdict. One GitHub Actions workflow runs both on a cron in an unprivileged `observe` job, then conditionally runs an `apply` job that carries `environment: vm-resize` — a protected environment whose reviewer gate is also the only way its Azure OIDC credential can be minted. The shell gathers, the Ruby decides, the environment authorises.

**Tech Stack:** Ruby 3.3.12 (stdlib only — no Bundler, no Rails), bash, `jq`, Azure CLI, GitHub Actions, RSpec.

**Spec:** `docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md`

## Global Constraints

- **Ruby is pinned to 3.3.12** and is not on `PATH` in non-login shells. Prefix local commands with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **`ops/vmscale/policy.rb` uses the Ruby standard library only.** No gems, no Bundler, no Rails, no autoloading. It must run as `ruby ops/vmscale/policy.rb` on a bare runner.
- **`policy.rb` is pure.** No network calls, no shelling out, no reading of the wall clock — `now_utc` arrives in its input. Every fact comes from stdin.
- **No threshold, comparison or verdict may appear in `gather.sh`.** The shell script is the untested half by necessity, so it must hold nothing worth testing.
- **`spec/ops/vmscale_policy_spec.rb` requires `spec_helper`, never `rails_helper`.** It must not boot Rails.
- **Never edit any file under `features/`.** The acceptance suite is frozen; see `CLAUDE.md`.
- **No credential literals in any committed file.** Azure client IDs go in GitHub Actions secrets and are referenced by name only.
- **Pin every GitHub Action to a commit SHA** with the version in a trailing comment, matching the existing workflows. This repo uses `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` and `azure/login@f5d393ae46f8fde4be8b75f32e3fc50e654ad0ca # v3.0.1`.
- **Exact threshold values**, copied from the spec — these are the numbers under test, do not round or adjust them:
  - `CREDIT_FLOOR_FRACTION = 0.30` (of the trailing 7-day maximum)
  - `MEMORY_FLOOR_BYTES = 200 * 1024 * 1024`
  - `CPU_BUSY_PERCENT = 80.0`, `CPU_BUSY_POINTS = 12`, `WINDOW_POINTS = 36`
  - `QUIET_DAYS_REQUIRED = 14`, `COOLDOWN_HOURS = 48`
  - `budget_ceiling_usd` default `45`, `baseline_usd` default `7.5`
- **The ladder is `Standard_B1ms` → `Standard_B2s` → `Standard_B2ms`**, ascending, floor first. Both directions move exactly one rung.
- **Azure targets:** resource group `MEZINEU`, VM `web`, subscription `5fe2e416-5389-40ea-a0a0-f8ae1ad8d19f`, health URL `https://game.mezin.eu/up`.

---

### Task 1: The ladder, the gatherer, and one real fixture

**Files:**
- Create: `ops/vmscale/ladder.json`
- Create: `ops/vmscale/gather.sh`
- Create: `spec/fixtures/vmscale/input-quiet-2026-08-20.json` (captured, not hand-written)

**Interfaces:**
- Consumes: nothing.
- Produces: `ops/vmscale/gather.sh` prints one JSON document on stdout with top-level keys `current_size` (String), `resize_options` (Array of String), `ladder` (Array of `{size, vcpu, ram_gib, usd, floor?}`), `budget_ceiling_usd` (Number), `baseline_usd` (Number), `now_utc` (String, ISO 8601 Z), `last_resize_utc` (String or null), `activity_log_readable` (Boolean), and `metrics` (Object with `cpu_percent`, `available_memory_bytes`, `cpu_credits_remaining`, `credits_max_7d`, `hourly_14d`). Point shapes: `{"t": String, "avg": Number}` for `cpu_percent`, `{"t": String, "min": Number}` for the other two.

- [ ] **Step 1: Create the ladder**

`ops/vmscale/ladder.json`:

```json
[
  { "size": "Standard_B1ms", "vcpu": 1, "ram_gib": 2, "usd": 17.52, "floor": true },
  { "size": "Standard_B2s",  "vcpu": 2, "ram_gib": 4, "usd": 35.04 },
  { "size": "Standard_B2ms", "vcpu": 2, "ram_gib": 8, "usd": 70.08 }
]
```

Prices are westeurope retail, fetched from `https://prices.azure.com/api/retail/prices` on 2026-08-20. This file is the only place a price is written down.

- [ ] **Step 2: Write the gatherer**

`ops/vmscale/gather.sh`:

```bash
#!/usr/bin/env bash
#
# Gathers everything ops/vmscale/policy.rb needs and prints it as one JSON
# document on stdout. Every `az` call in the VM scaling system lives here, and
# no threshold, comparison or verdict does -- the shell gathers, the Ruby
# decides. See docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md.
#
# Requires: az (already logged in) and jq. Both are present on ubuntu-latest.
set -euo pipefail

RG="${RG:-MEZINEU}"
VM="${VM:-web}"
LADDER="${LADDER:-ops/vmscale/ladder.json}"
BUDGET_CEILING_USD="${BUDGET_CEILING_USD:-45}"
BASELINE_USD="${BASELINE_USD:-7.5}"

ID="$(az vm show -g "$RG" -n "$VM" --query id -o tsv)"
SIZE="$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv)"
OPTIONS="$(az vm list-vm-resize-options -g "$RG" -n "$VM" --query '[].name' -o json)"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FROM_3H="$(date -u -d '3 hours ago'  +%Y-%m-%dT%H:%M:%SZ)"
FROM_7D="$(date -u -d '7 days ago'   +%Y-%m-%dT%H:%M:%SZ)"
FROM_14D="$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)"

window() {  # $1 = interval, $2 = start time
  az monitor metrics list --resource "$ID" \
     --metric "Percentage CPU" "Available Memory Bytes" "CPU Credits Remaining" \
     --interval "$1" --start-time "$2" --end-time "$NOW" \
     --aggregation Average Minimum -o json
}

W3H="$(window PT5M "$FROM_3H")"
W14D="$(window PT1H "$FROM_14D")"

# What "30% of peak credits" is measured against. Taken as an observed maximum
# rather than assumed from the SKU, because the banked ceiling depends on how
# long the VM has been up.
CREDITS_MAX_7D="$(az monitor metrics list --resource "$ID" \
    --metric "CPU Credits Remaining" --interval PT1H \
    --start-time "$FROM_7D" --end-time "$NOW" --aggregation Maximum -o json \
  | jq '[.value[0].timeseries[0].data[] | .maximum // empty] | max // 0')"

# The Activity Log is a SUBSCRIPTION-level resource and this identity is scoped
# to one VM, so this query may legitimately be forbidden. It must not be fatal
# -- but it must not be silent either, so the failure is reported in the output
# and policy.rb says on every verdict that the cooldown is not in force.
#
# Microsoft.Compute/virtualMachines/write also covers any VM update, not only a
# resize. Erring wide is correct: the worst case is an unrelated tag edit
# postponing a proposal by up to 48 hours.
ACTIVITY_READABLE=true
if ! LAST_RESIZE="$(az monitor activity-log list --resource-id "$ID" --offset 30d \
      --query "sort_by([?authorization.action=='Microsoft.Compute/virtualMachines/write' && status.value=='Succeeded'], &eventTimestamp)[-1].eventTimestamp" \
      -o tsv 2>/dev/null)"; then
  ACTIVITY_READABLE=false
  LAST_RESIZE=""
fi
[ "$LAST_RESIZE" = "None" ] && LAST_RESIZE=""

# A point for an interval Azure had no data for arrives with its aggregation key
# ABSENT, not zero. `select(has($key))` drops those. This is load-bearing: a
# missing `minimum` on Available Memory Bytes coerced to 0 would manufacture the
# most severe breach the engine can see, out of nothing.
jq -n \
  --arg     size        "$SIZE" \
  --argjson options     "$OPTIONS" \
  --argjson ladder      "$(cat "$LADDER")" \
  --argjson ceiling     "$BUDGET_CEILING_USD" \
  --argjson baseline    "$BASELINE_USD" \
  --arg     now         "$NOW" \
  --arg     last        "$LAST_RESIZE" \
  --argjson readable    "$ACTIVITY_READABLE" \
  --argjson credits_max "$CREDITS_MAX_7D" \
  --argjson w3h         "$W3H" \
  --argjson w14d        "$W14D" \
  '
  def pick($src; $metric; $key; $out):
    [ $src.value[]
      | select(.name.value == $metric)
      | .timeseries[0].data[]
      | select(has($key))
      | { t: .timeStamp, ($out): .[$key] } ];

  def shape($src):
    {
      cpu_percent:            pick($src; "Percentage CPU";         "average"; "avg"),
      available_memory_bytes: pick($src; "Available Memory Bytes"; "minimum"; "min"),
      cpu_credits_remaining:  pick($src; "CPU Credits Remaining";  "minimum"; "min")
    };

  {
    current_size:           $size,
    resize_options:         $options,
    ladder:                 $ladder,
    budget_ceiling_usd:     $ceiling,
    baseline_usd:           $baseline,
    now_utc:                $now,
    last_resize_utc:        (if $last == "" then null else $last end),
    activity_log_readable:  $readable,
    metrics: (
      shape($w3h)
      + { credits_max_7d: $credits_max, hourly_14d: shape($w14d) }
    )
  }'
```

- [ ] **Step 3: Make it executable and run it against the real VM**

```bash
chmod +x ops/vmscale/gather.sh
az account show >/dev/null   # must already be logged in; if not, run: az login
mkdir -p spec/fixtures/vmscale
./ops/vmscale/gather.sh > spec/fixtures/vmscale/input-quiet-2026-08-20.json
```

Expected: exits 0, writes a JSON file of roughly 40–120 KB.

- [ ] **Step 4: Verify the captured shape**

```bash
jq '{
  size: .current_size,
  options: (.resize_options | length),
  cpu: (.metrics.cpu_percent | length),
  mem: (.metrics.available_memory_bytes | length),
  credits: (.metrics.cpu_credits_remaining | length),
  credits_max: .metrics.credits_max_7d,
  hourly_cpu: (.metrics.hourly_14d.cpu_percent | length),
  readable: .activity_log_readable
}' spec/fixtures/vmscale/input-quiet-2026-08-20.json
```

Expected: `size` is `"Standard_B1ms"`; `cpu`, `mem` and `credits` are each **at least 36**; `credits_max` is around `288`; `hourly_cpu` is in the low hundreds (14 days of hourly buckets, ~336). If any of the three 3-hour series is under 36, widen `FROM_3H` — the engine treats a short window as insufficient data and will only ever return `hold`.

Also confirm no point was defaulted to zero, which would mean the `has($key)` filter is not doing its job:

```bash
jq '[.metrics.available_memory_bytes[] | select(.min == 0)] | length' \
  spec/fixtures/vmscale/input-quiet-2026-08-20.json
```

Expected: `0`.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/ladder.json ops/vmscale/gather.sh spec/fixtures/vmscale/input-quiet-2026-08-20.json
git commit -m "Gather the VM's load profile into one JSON document

Every az call in the scaling system lives in gather.sh and no threshold
does. Points for intervals Azure had no data for arrive with their
aggregation key absent and are dropped rather than defaulted -- a
missing minimum on Available Memory Bytes coerced to 0 would
manufacture the most severe breach the engine can see, out of nothing.

The captured fixture is real output against the production VM, which is
what makes the 'this must return hold' test meaningful."
```

---

### Task 2: The decision contract, and `hold` on real quiet data

**Files:**
- Create: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: the JSON document from Task 1.
- Produces: `VMScale::Policy.decide(input) -> Hash` with String keys `"verdict"` (one of `"hold"`, `"scale_up"`, `"scale_down"`, `"at_budget_ceiling"`), `"current"` (String), `"target"` (String or nil), `"reasons"` (Array of String, never empty), `"evidence"` (Hash). Also `VMScale::Policy.evidence(input) -> Hash` with keys `"window_points"`, `"cpu_busy_points"`, `"cpu_max_percent"`, `"memory_min_mb"`, `"credits_min"`, `"credits_max_7d"`, `"quiet_days"`.

- [ ] **Step 1: Write the failing test**

`spec/ops/vmscale_policy_spec.rb`:

```ruby
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
end
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: FAIL — `cannot load such file -- .../ops/vmscale/policy`.

- [ ] **Step 3: Write the minimal implementation**

`ops/vmscale/policy.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Pure decision function for the VM scaling proposer (Track 1).
#
# Reads the JSON document ops/vmscale/gather.sh produces on stdin and writes a
# verdict on stdout. It makes no network calls, shells out to nothing and reads
# no clock -- `now_utc` arrives in the input. That purity is the point: it is
# testable from fixtures alone, and when the executor is replaced in Track 3
# this file does not change.
#
# See docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md.

require "json"
require "time"

module VMScale
  module Policy
    CREDIT_FLOOR_FRACTION = 0.30
    MEMORY_FLOOR_BYTES    = 200 * 1024 * 1024
    CPU_BUSY_PERCENT      = 80.0
    CPU_BUSY_POINTS       = 12
    WINDOW_POINTS         = 36
    QUIET_DAYS_REQUIRED   = 14
    COOLDOWN_HOURS        = 48
    MB                    = 1024 * 1024

    module_function

    def decide(input)
      verdict("hold", input.fetch("current_size"), nil, evidence(input),
              ["no threshold breached"])
    end

    def evidence(input)
      metrics = input.fetch("metrics")
      cpu     = metrics["cpu_percent"] || []
      {
        "window_points"   => cpu.size,
        "cpu_busy_points" => busy_points(cpu),
        "cpu_max_percent" => (cpu.filter_map { |p| p["avg"]&.to_f }.max || 0).round(1),
        "memory_min_mb"   => ((minimum(metrics["available_memory_bytes"]) || 0) / MB).round,
        "credits_min"     => (minimum(metrics["cpu_credits_remaining"]) || 0).round(1),
        "credits_max_7d"  => metrics["credits_max_7d"],
        "quiet_days"      => 0
      }
    end

    def minimum(points)
      (points || []).filter_map { |p| p["min"]&.to_f }.min
    end

    def busy_points(points)
      (points || []).count { |p| p["avg"].to_f > CPU_BUSY_PERCENT }
    end

    def verdict(name, current, target, evidence, reasons)
      {
        "verdict"  => name,
        "current"  => current,
        "target"   => target,
        "reasons"  => reasons,
        "evidence" => evidence
      }
    end
  end
end
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 5 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Decide nothing, in the right shape

The contract first: a verdict, a current size, an optional target, a
non-empty reason list and the computed aggregates. Reasons are
populated even for hold, because a log that records only exceptions
cannot answer whether it was quiet or the poller was broken."
```

---

### Task 3: The credit-depletion trigger

**Files:**
- Modify: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: `VMScale::Policy.decide`, `.minimum`, `.verdict` from Task 2.
- Produces: `VMScale::Policy.breaches(input) -> Array<String>` — one human-readable line per breached threshold, empty when none. `VMScale::Policy.step(ladder, current, direction) -> String or nil` where `direction` is `+1` or `-1`.

- [ ] **Step 1: Write the failing test**

Append inside the `RSpec.describe VMScale::Policy do` block:

```ruby
  # Drive every point of a series to a fixed value, in both the 3-hour window
  # and the 14-day hourly rollup, so a case cannot accidentally stay quiet in
  # one window while breaching in the other.
  def flood(input, series, key, value)
    input["metrics"][series].each { |p| p[key] = value }
    input["metrics"]["hourly_14d"][series].each { |p| p[key] = value }
  end

  describe "credit depletion" do
    # 22% of the 288 ceiling, well under the 30% floor.
    let(:draining) { build { |i| flood(i, "cpu_credits_remaining", "min", 63.4) } }

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
      just_inside  = build { |i| flood(i, "cpu_credits_remaining", "min", 86.5) }
      just_outside = build { |i| flood(i, "cpu_credits_remaining", "min", 86.3) }

      expect(described_class.decide(just_inside)["verdict"]).to eq("hold")
      expect(described_class.decide(just_outside)["verdict"]).to eq("scale_up")
    end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb -e "credit depletion"
```

Expected: FAIL — `expected: "scale_up", got: "hold"`.

- [ ] **Step 3: Implement the trigger and the ladder step**

Replace `decide` in `ops/vmscale/policy.rb` and add the two new methods:

```ruby
    def decide(input)
      current  = input.fetch("current_size")
      found    = evidence(input)
      breached = breaches(input)

      return scale_up(input, current, found, breached) if breached.any?

      verdict("hold", current, nil, found, ["no threshold breached"])
    end

    def scale_up(input, current, found, breached)
      target = step(input.fetch("ladder"), current, +1)
      if target.nil?
        return verdict("hold", current, nil, found,
                       breached + ["#{current} is the top of the ladder"])
      end

      verdict("scale_up", current, target, found, breached)
    end

    def breaches(input)
      metrics = input.fetch("metrics")
      found   = []

      ceiling = metrics.fetch("credits_max_7d").to_f
      lowest  = minimum(metrics["cpu_credits_remaining"])
      floor   = ceiling * CREDIT_FLOOR_FRACTION
      if lowest && ceiling.positive? && lowest < floor
        found << format("cpu credits: min %.1f below %.1f (%d%% of the 7-day max %.1f)",
                        lowest, floor, (CREDIT_FLOOR_FRACTION * 100).round, ceiling)
      end

      found
    end

    def step(ladder, current, direction)
      here = ladder.index { |rung| rung.fetch("size") == current }
      return nil if here.nil?

      there = here + direction
      return nil if there.negative? || there >= ladder.size

      ladder[there].fetch("size")
    end
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 9 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Trigger on credit depletion, not CPU percentage

On a burstable SKU, CPU at 100% is the product working -- this VM peaks
at 99% and has spent three credits of 288 in a week. Running the bank
to zero is what actually throttles it to a 20% baseline, at which point
the site is unusable while Percentage CPU reports a serene 20%.

The mutation check is the point of the test: 86.5 holds and 86.3 fires,
so the constant is load-bearing rather than decorative."
```

---

### Task 4: The memory-floor trigger

**Files:**
- Modify: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: `VMScale::Policy.breaches` from Task 3.
- Produces: no new public methods; `breaches` gains a second rule.

- [ ] **Step 1: Write the failing test**

Append inside the describe block:

```ruby
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
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb -e "the memory floor"
```

Expected: FAIL — `expected: "scale_up", got: "hold"`.

- [ ] **Step 3: Add the rule**

In `ops/vmscale/policy.rb`, inside `breaches`, immediately before `found` is returned:

```ruby
      lowest_memory = minimum(metrics["available_memory_bytes"])
      if lowest_memory && lowest_memory < MEMORY_FLOOR_BYTES
        found << format("available memory: min %d MB below the %d MB floor",
                        (lowest_memory / MB).round, MEMORY_FLOOR_BYTES / MB)
      end
```

`minimum` already uses `filter_map { |p| p["min"]&.to_f }`, so a point with the key absent contributes nothing and an all-absent series yields `nil` — which is why the last example passes without further work.

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 14 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Trigger on the memory floor

The axis with an actual floor: 472 MB free at the worst observed moment,
on a host that also carries Postgres, kamal-proxy, danted and the APRS
forwarders. There is no graceful degradation here -- memory pressure
does not slow the site down, it invokes the OOM killer, and recovery
from that is a restore rather than a resize.

An absent reading is proved not to read as zero bytes free."
```

---

### Task 5: The sustained-CPU trigger

**Files:**
- Modify: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: `VMScale::Policy.breaches`, `.busy_points` from Tasks 2–3.
- Produces: no new public methods; `breaches` gains a third rule.

- [ ] **Step 1: Write the failing test**

Append inside the describe block:

```ruby
  describe "sustained cpu" do
    # Set the first N points busy and the rest idle, in the 3-hour window only.
    def with_busy_points(count)
      build do |i|
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
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb -e "sustained cpu"
```

Expected: FAIL — `expected: "scale_up", got: "hold"`.

- [ ] **Step 3: Add the rule**

In `ops/vmscale/policy.rb`, inside `breaches`, immediately before `found` is returned:

```ruby
      window = metrics["cpu_percent"] || []
      busy   = busy_points(window)
      if busy >= CPU_BUSY_POINTS
        found << format("sustained cpu: %d of %d points above %d%%",
                        busy, window.size, CPU_BUSY_PERCENT.round)
      end
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 18 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Trigger on sustained CPU, corroborating rather than deciding

Twelve of thirty-six five-minute points above 80% is an hour of real
load, not a deploy. Three points at 99% is a deploy, and holds.

This rule earns its place because a sustained-CPU pattern with credits
still healthy is the signature of a new steady load rather than a
spike -- which is exactly the growth this whole exercise watches for."
```

---

### Task 6: One rung at a time, and the budget ceiling

**Files:**
- Modify: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: `VMScale::Policy.scale_up`, `.step` from Task 3.
- Produces: `VMScale::Policy.monthly_total(input, size) -> Float`. `scale_up` may now return the verdict `"at_budget_ceiling"` with a nil target.

- [ ] **Step 1: Write the failing test**

Append inside the describe block:

```ruby
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
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb -e "the budget ceiling"
```

Expected: FAIL — `expected: "at_budget_ceiling", got: "scale_up"`.

- [ ] **Step 3: Implement the ceiling**

Replace `scale_up` in `ops/vmscale/policy.rb` and add `monthly_total`:

```ruby
    def scale_up(input, current, found, breached)
      target = step(input.fetch("ladder"), current, +1)
      if target.nil?
        return verdict("hold", current, nil, found,
                       breached + ["#{current} is the top of the ladder"])
      end

      cost    = monthly_total(input, target)
      ceiling = input.fetch("budget_ceiling_usd").to_f
      if cost > ceiling
        # A distinct verdict on purpose. Folding this into "hold" would hide
        # the most important signal the engine can produce; folding it into
        # "scale_up" would propose an action that takes the subscription --
        # and therefore the platform -- offline.
        return verdict("at_budget_ceiling", current, nil, found,
                       breached + [format("%s would cost $%.2f/mo, over the $%.2f ceiling",
                                          target, cost, ceiling)])
      end

      verdict("scale_up", current, target, found, breached)
    end

    def monthly_total(input, size)
      rung = input.fetch("ladder").find { |r| r.fetch("size") == size }
      raise KeyError, "#{size} is not on the ladder" if rung.nil?

      rung.fetch("usd").to_f + input.fetch("baseline_usd").to_f
    end
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 24 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Refuse to propose a rung that breaches the budget

The subscription is credit-based and a credit subscription that reaches
its spending limit disables rather than degrades -- the platform would
go dark abruptly. B2ms at \$77.58/mo against a ~\$50 credit is that
cliff, so at_budget_ceiling is its own verdict: the same evidence, but
the decision has become a business one rather than an ops one.

One rung at a time in both directions, however dramatic the evidence."
```

---

### Task 7: The suppressors — cooldown, cluster availability, missing data

**Files:**
- Modify: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: `VMScale::Policy.decide`, `.scale_up` from Tasks 3 and 6.
- Produces: `VMScale::Policy.cooldown_remaining_hours(input) -> Float or nil` (nil when no cooldown applies), `VMScale::Policy.metrics_gap(input) -> String or nil` (nil when the data is sufficient). `REQUIRED_SERIES` constant.

- [ ] **Step 1: Write the failing test**

Append inside the describe block:

```ruby
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
  end
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb -e "suppressors"
```

Expected: FAIL — the first example gets `"scale_up"` instead of `"hold"`.

- [ ] **Step 3: Implement the suppressors**

Add the constant beside the others in `ops/vmscale/policy.rb`:

```ruby
    REQUIRED_SERIES = %w[cpu_percent available_memory_bytes cpu_credits_remaining].freeze
```

Replace `decide`, extend `scale_up` with the availability check, and add the two new methods:

```ruby
    def decide(input)
      current = input.fetch("current_size")
      found   = evidence(input)
      caveats = input.fetch("activity_log_readable", true) ? [] :
                  ["activity log unreadable: the cooldown is not in force"]

      # Checked first, and before the data check, so that a resize minutes old
      # is never masked by an unrelated metrics gap.
      if (remaining = cooldown_remaining_hours(input))
        return verdict("hold", current, nil, found, caveats +
          [format("cooldown: %.1fh of %dh remaining since the last resize",
                  remaining, COOLDOWN_HOURS)])
      end

      if (gap = metrics_gap(input))
        return verdict("hold", current, nil, found, caveats + [gap])
      end

      breached = breaches(input)
      return scale_up(input, current, found, caveats + breached) if breached.any?

      verdict("hold", current, nil, found, caveats + ["no threshold breached"])
    end

    def cooldown_remaining_hours(input)
      last = input["last_resize_utc"]
      return nil if last.nil? || last.to_s.empty?

      elapsed = (Time.parse(input.fetch("now_utc")) - Time.parse(last)) / 3600.0
      return nil if elapsed.negative? || elapsed >= COOLDOWN_HOURS

      COOLDOWN_HOURS - elapsed
    end

    def metrics_gap(input)
      metrics = input.fetch("metrics")

      REQUIRED_SERIES.each do |name|
        size = (metrics[name] || []).size
        if size < WINDOW_POINTS
          return "insufficient data: #{name} returned #{size} of #{WINDOW_POINTS} expected points"
        end
      end

      return "insufficient data: credits_max_7d is missing or zero" unless
        metrics["credits_max_7d"].to_f.positive?

      nil
    end
```

And in `scale_up`, between the top-of-ladder check and the cost check:

```ruby
      unless input.fetch("resize_options").include?(target)
        # This list is a property of the physical cluster the VM sits on. A
        # target absent from it would need a deallocate/start cycle rather than
        # a reboot -- a materially different operation, never by surprise.
        return verdict("hold", current, nil, found,
                       breached + ["#{target} is not offered by the cluster this VM sits on"])
      end
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 32 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Suppress proposals on cooldown, cluster limits and thin data

Three ways to decline. The cooldown is checked first so a resize minutes
old is never masked by an unrelated metrics gap. A target the current
cluster does not offer would need a deallocate/start cycle rather than a
reboot, which must never happen by surprise. And a short window or a
missing credit ceiling produces hold and says why -- the engine never
infers a breach from data it does not have.

When the activity log cannot be read the cooldown cannot apply, and
every verdict says so rather than letting it lapse quietly."
```

---

### Task 8: Scale down, after fourteen quiet days

**Files:**
- Modify: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: `VMScale::Policy.decide`, `.step`, `.evidence` from earlier tasks.
- Produces: `VMScale::Policy.quiet_days(input) -> Integer`, `VMScale::Policy.scale_down(input, current, found, caveats) -> Hash`, `VMScale::Policy.by_day(points) { |points_for_day| ... } -> Hash{String => Object}`. `evidence`'s `"quiet_days"` now carries the real count.

- [ ] **Step 1: Write the failing test**

Append inside the describe block:

```ruby
  describe "scaling down" do
    # Replace the hourly rollup with `days` days of uniformly quiet hours,
    # ending on the day before now_utc so no partial day is involved.
    def with_quiet_history(input, days)
      finish = Time.parse(input.fetch("now_utc"))
      hours  = (1..(days * 24)).map do |ago|
        stamp = (finish - (ago * 3600)).strftime("%Y-%m-%dT%H:00:00Z")
        { "t" => stamp }
      end

      input["metrics"]["hourly_14d"] = {
        "cpu_percent"            => hours.map { |h| h.merge("avg" => 4.0) },
        "available_memory_bytes" => hours.map { |h| h.merge("min" => 900 * 1024 * 1024) },
        "cpu_credits_remaining"  => hours.map { |h| h.merge("min" => 287.0) }
      }
      input
    end

    let(:on_b2s) do
      build do |i|
        i["current_size"] = "Standard_B2s"
        with_quiet_history(i, 15)
      end
    end

    it "proposes the rung below after fourteen quiet days" do
      result = described_class.decide(on_b2s)
      expect(result["verdict"]).to eq("scale_down")
      expect(result["target"]).to eq("Standard_B1ms")
    end

    it "holds at thirteen" do
      nearly = build do |i|
        i["current_size"] = "Standard_B2s"
        with_quiet_history(i, 13)
      end
      result = described_class.decide(nearly)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join).to match(/13 of 14 quiet days/)
    end

    it "resets the streak on a single busy hour" do
      # One hour averaging above 80% can only be sustained load, unlike a daily
      # maximum, which cannot tell a five-minute deploy spike from real work.
      interrupted = build do |i|
        i["current_size"] = "Standard_B2s"
        with_quiet_history(i, 15)
        i["metrics"]["hourly_14d"]["cpu_percent"][60]["avg"] = 88.0
      end
      expect(described_class.decide(interrupted)["verdict"]).to eq("hold")
    end

    it "tolerates the daily CPU peaks this VM actually has" do
      # The production reality: 90-99% peaks most days, three credits a week.
      # Those are five-minute spikes and must not block a scale-down forever.
      spiky = build do |i|
        i["current_size"] = "Standard_B2s"
        with_quiet_history(i, 15)
        i["metrics"]["hourly_14d"]["cpu_percent"].each_slice(24) { |day| day.first["avg"] = 60.0 }
      end
      expect(described_class.decide(spiky)["verdict"]).to eq("scale_down")
    end

    it "never proposes below the floor" do
      floored = build { |i| with_quiet_history(i, 15) }   # already Standard_B1ms
      result = described_class.decide(floored)
      expect(result["verdict"]).to eq("hold")
      expect(result["reasons"].join).to match(/Standard_B1ms is the floor/)
    end

    it "reports the streak as evidence" do
      expect(described_class.decide(on_b2s)["evidence"]["quiet_days"]).to be >= 14
    end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb -e "scaling down"
```

Expected: FAIL — `expected: "scale_down", got: "hold"`.

- [ ] **Step 3: Implement the scale-down path**

In `ops/vmscale/policy.rb`, change the final line of `decide` from the bare `hold` to:

```ruby
      scale_down(input, current, found, caveats)
```

Add the three methods:

```ruby
    def scale_down(input, current, found, caveats)
      quiet  = found.fetch("quiet_days")
      target = step(input.fetch("ladder"), current, -1)

      if target.nil?
        return verdict("hold", current, nil, found,
                       caveats + ["no threshold breached; #{current} is the floor"])
      end

      if quiet < QUIET_DAYS_REQUIRED
        return verdict("hold", current, nil, found,
                       caveats + ["no threshold breached; #{quiet} of #{QUIET_DAYS_REQUIRED} quiet days"])
      end

      unless input.fetch("resize_options").include?(target)
        return verdict("hold", current, nil, found,
                       caveats + ["#{quiet} quiet days, but #{target} is not offered by the cluster this VM sits on"])
      end

      verdict("scale_down", current, target, found, caveats + ["#{quiet} consecutive quiet days"])
    end

    # A day is quiet when no hour averaged above the CPU line, the lowest
    # available memory stayed above the floor, and the lowest credit balance
    # stayed above 30% of the seven-day peak.
    #
    # Hours, not daily maxima. This VM peaks at 90-99% on most days from
    # deploys and translation runs while spending three credits a week; a daily
    # maximum would score every day busy and scale-down could never fire. An
    # hour whose AVERAGE exceeds 80% can only be sustained load.
    def quiet_days(input)
      metrics = input.fetch("metrics")
      hourly  = metrics["hourly_14d"]
      return 0 if hourly.nil?

      ceiling = metrics.fetch("credits_max_7d").to_f
      floor   = ceiling * CREDIT_FLOOR_FRACTION

      busy    = by_day(hourly["cpu_percent"]) { |hours| busy_points(hours).positive? }
      memory  = by_day(hourly["available_memory_bytes"]) { |hours| minimum(hours) }
      credits = by_day(hourly["cpu_credits_remaining"]) { |hours| minimum(hours) }

      streak = 0
      (busy.keys | memory.keys | credits.keys).sort.reverse_each do |day|
        break if busy[day]
        break if memory[day] && memory[day] < MEMORY_FLOOR_BYTES
        break if credits[day] && ceiling.positive? && credits[day] < floor

        streak += 1
      end
      streak
    end

    def by_day(points)
      (points || []).group_by { |point| point.fetch("t")[0, 10] }
                    .transform_values { |hours| yield(hours) }
    end
```

And in `evidence`, replace `"quiet_days" => 0` with:

```ruby
        "quiet_days"      => quiet_days(input)
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 38 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Propose a scale-down after fourteen quiet days

Quiet is measured in hours, not daily maxima, and the test proves why:
this VM peaks at 90-99% on most days from deploys and translation runs
while spending three credits a week. A daily maximum would score every
day busy and scale-down could never have fired. An hour whose average
exceeds 80% can only be sustained load.

Fourteen days against forty-eight hours the other way is deliberate.
Scaling up spends money against a ceiling that disables the
subscription; scaling down only risks performance, but still costs a
reboot, so a hair-trigger would trade real downtime for pennies."
```

---

### Task 9: The command-line entry point

**Files:**
- Modify: `ops/vmscale/policy.rb`
- Test: `spec/ops/vmscale_policy_spec.rb`

**Interfaces:**
- Consumes: `VMScale::Policy.decide`.
- Produces: `ruby ops/vmscale/policy.rb < input.json` prints the verdict as JSON on stdout and exits 0; malformed or incomplete input exits non-zero with a message on stderr.

- [ ] **Step 1: Write the failing test**

Append inside the describe block:

```ruby
  describe "the command line" do
    let(:script)  { File.expand_path("../../ops/vmscale/policy.rb", __dir__) }
    let(:fixture) { File.expand_path("../fixtures/vmscale/input-quiet-2026-08-20.json", __dir__) }

    it "prints a verdict and exits 0" do
      output = `ruby #{script} < #{fixture}`
      expect($CHILD_STATUS.exitstatus).to eq(0)
      expect(JSON.parse(output)["verdict"]).to eq("hold")
    end

    it "exits non-zero on malformed input" do
      `echo 'not json' | ruby #{script} 2>/dev/null`
      expect($CHILD_STATUS.exitstatus).not_to eq(0)
    end

    it "exits non-zero rather than guessing when a key is missing" do
      `echo '{}' | ruby #{script} 2>/dev/null`
      expect($CHILD_STATUS.exitstatus).not_to eq(0)
    end
  end
```

Add `require "English"` to the top of the spec file, beside `require "json"`, so `$CHILD_STATUS` is available.

- [ ] **Step 2: Run it to confirm it fails**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb -e "the command line"
```

Expected: FAIL — the output is empty, so `JSON.parse` raises `unexpected token at ''`.

- [ ] **Step 3: Add the entry point**

At the very bottom of `ops/vmscale/policy.rb`, after the final `end` that closes `module VMScale`:

```ruby
# Deliberately not a `bin/` script and not wired into Rails. An uncaught
# exception here is the correct behaviour: a non-zero exit means the engine
# itself failed, and the workflow must not proceed on a verdict it did not get.
if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(VMScale::Policy.decide(JSON.parse($stdin.read)))
end
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
bundle exec rspec spec/ops/vmscale_policy_spec.rb
```

Expected: PASS, 41 examples, 0 failures.

Then confirm by hand that the two halves fit together:

```bash
./ops/vmscale/gather.sh | ruby ops/vmscale/policy.rb
```

Expected: a verdict of `hold` against live production metrics.

- [ ] **Step 5: Commit**

```bash
git add ops/vmscale/policy.rb spec/ops/vmscale_policy_spec.rb
git commit -m "Run the engine from the command line

A non-zero exit means the engine failed, and the workflow must not
proceed on a verdict it never received -- so nothing is rescued here."
```

---

### Task 10: The Azure and GitHub setup runbook

**Files:**
- Create: `docs/runbooks/vm-scaling-setup.md`

**Interfaces:**
- Consumes: nothing in code.
- Produces: the GitHub Actions secrets `AZURE_VMSCALE_READER_CLIENT_ID` and `AZURE_VMSCALE_OPERATOR_CLIENT_ID`, the GitHub Environment `vm-resize` with a required reviewer, and the label `vm-scaling-log` on an open issue. Task 11's workflow depends on all of these existing.

> **This task writes the runbook. It does not run it.** The commands create Azure identities, grant roles and change repository settings — the repository owner runs them, and Task 11 cannot be verified until they have.

- [ ] **Step 1: Write the runbook**

`docs/runbooks/vm-scaling-setup.md`:

````markdown
# Setting up VM scaling (Track 1)

One-time setup for `.github/workflows/vm-scale.yml`. See
`docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md` for why it is shaped this way.

The design's central guarantee is that **the credential able to resize the VM cannot be
issued until a human approves**. That rests entirely on the configuration below, so §5
re-verifies it rather than assuming it.

```bash
export SUB=5fe2e416-5389-40ea-a0a0-f8ae1ad8d19f
export RG=MEZINEU
export REPO=mezinster/encounter-engine
export VM_ID=$(az vm show -g $RG -n web --query id -o tsv)
export ISSUER=https://token.actions.githubusercontent.com
```

## 1. The reader identity

Runs unattended on a cron. Read-only, and scoped to the one VM.

```bash
az identity create -g $RG -n vmscale-reader
READER_PRINCIPAL=$(az identity show -g $RG -n vmscale-reader --query principalId -o tsv)
READER_CLIENT=$(az identity show -g $RG -n vmscale-reader --query clientId -o tsv)

az role assignment create --assignee-object-id "$READER_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal --role "Monitoring Reader" --scope "$VM_ID"
az role assignment create --assignee-object-id "$READER_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal --role "Reader" --scope "$VM_ID"

az identity federated-credential create --name github-master \
  --identity-name vmscale-reader -g $RG \
  --issuer "$ISSUER" \
  --subject "repo:$REPO:ref:refs/heads/master" \
  --audiences api://AzureADTokenExchange

echo "$READER_CLIENT"
```

## 2. The operator identity

Exists only behind the reviewer gate. Its federated credential trusts the **environment**,
not a branch — which is what makes approval and authorisation the same act.

```bash
az identity create -g $RG -n vmscale-operator
OPERATOR_PRINCIPAL=$(az identity show -g $RG -n vmscale-operator --query principalId -o tsv)
OPERATOR_CLIENT=$(az identity show -g $RG -n vmscale-operator --query clientId -o tsv)

az role assignment create --assignee-object-id "$OPERATOR_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" --scope "$VM_ID"

az identity federated-credential create --name github-vm-resize \
  --identity-name vmscale-operator -g $RG \
  --issuer "$ISSUER" \
  --subject "repo:$REPO:environment:vm-resize" \
  --audiences api://AzureADTokenExchange

echo "$OPERATOR_CLIENT"
```

## 3. The GitHub environment and secrets

The environment must exist **and** carry a required reviewer. Without the reviewer it is
an ordinary environment and the gate is gone — the workflow would resize unattended.
Create it in the UI (Settings → Environments → New environment → `vm-resize` → Required
reviewers → add yourself), then:

```bash
gh secret set AZURE_VMSCALE_READER_CLIENT_ID   --repo $REPO --body "$READER_CLIENT"
gh secret set AZURE_VMSCALE_OPERATOR_CLIENT_ID --repo $REPO --body "$OPERATOR_CLIENT"
```

`AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` already exist for the deploy workflow and
are reused.

## 4. The decision log issue

```bash
gh label create vm-scaling-log --repo $REPO --color 0e8a16 \
  --description "The VM scaling proposer's decision log"
gh issue create --repo $REPO --label vm-scaling-log \
  --title "VM scaling — decision log" \
  --body "Proposals and outcomes from .github/workflows/vm-scale.yml. Do not close: the workflow comments on the newest open issue carrying this label."
```

## 5. Verify the guarantee

Run all five. Any failure means the approval gate is not what the design claims.

```bash
# a. The environment has a required reviewer.
gh api repos/$REPO/environments/vm-resize \
  --jq '.protection_rules[] | select(.type=="required_reviewers") | .reviewers[].reviewer.login'
# Expect: your username. Empty output means the gate does not exist.

# b. The operator identity trusts exactly one subject, and it is the environment.
az identity federated-credential list --identity-name vmscale-operator -g $RG \
  --query '[].{name:name, subject:subject}' -o table
# Expect: exactly one row, subject repo:mezinster/encounter-engine:environment:vm-resize

# c. The reader holds no write role anywhere.
az role assignment list --assignee "$READER_PRINCIPAL" --all \
  --query '[].{role:roleDefinitionName, scope:scope}' -o table
# Expect: only "Monitoring Reader" and "Reader", both scoped to the web VM.

# d. Neither identity holds anything at subscription or resource-group scope.
for P in "$READER_PRINCIPAL" "$OPERATOR_PRINCIPAL"; do
  az role assignment list --assignee "$P" --all --query "[?scope=='/subscriptions/$SUB' || scope=='/subscriptions/$SUB/resourceGroups/$RG']" -o tsv
done
# Expect: no output at all.

# e. The reader can actually read what gather.sh needs.
az monitor metrics list --resource "$VM_ID" --metric "CPU Credits Remaining" \
  --interval PT1H --aggregation Maximum -o none && echo "metrics ok"
az monitor activity-log list --resource-id "$VM_ID" --offset 1d -o none \
  && echo "activity log ok" \
  || echo "activity log NOT readable -- expected; gather.sh reports it and the cooldown is disabled, loudly"
```

Check (e) is the one that may legitimately fail. The Activity Log is a subscription-level
resource, and the reader is scoped to one VM. If it fails, decide deliberately: either
accept running without the cooldown (`gather.sh` reports it and every verdict says so), or
grant `Monitoring Reader` at subscription scope and accept the wider read. Do not "fix" it
by widening silently.

## 6. Undo

```bash
az identity delete -g $RG -n vmscale-reader
az identity delete -g $RG -n vmscale-operator
gh secret delete AZURE_VMSCALE_READER_CLIENT_ID   --repo $REPO
gh secret delete AZURE_VMSCALE_OPERATOR_CLIENT_ID --repo $REPO
```

Role assignments are removed with the identities. The `vm-resize` environment and the log
issue can stay; they cost nothing and hold the history.
````

- [ ] **Step 2: Check the runbook's own commands parse**

```bash
bash -n <(sed -n '/```bash/,/```/p' docs/runbooks/vm-scaling-setup.md | grep -v '^```')
```

Expected: no output (a syntax error prints to stderr and exits non-zero).

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/vm-scaling-setup.md
git commit -m "Runbook: set up the VM scaling identities and gate

Two identities rather than one. The poller reads and nothing else; the
operator's federated credential trusts the environment rather than a
branch, which is what makes approval and authorisation the same act.

Section 5 verifies the guarantee instead of assuming it, including the
one check expected to fail: the Activity Log is subscription-scoped and
the reader is not. That is a deliberate choice between running without
the cooldown, loudly, and widening the read -- not something to fix by
quietly granting more."
```

- [ ] **Step 4: Hand it to the repository owner**

Stop here and ask them to run sections 1–5. Task 11 cannot be verified until the secrets,
the environment and the label exist.

---

### Task 11: The workflow

**Files:**
- Create: `.github/workflows/vm-scale.yml`

**Interfaces:**
- Consumes: `ops/vmscale/gather.sh` and `ops/vmscale/policy.rb` from Tasks 1–9; the secrets, environment and label from Task 10.
- Produces: a scheduled and manually dispatchable workflow whose `observe` job outputs `verdict`, `target` and `apply`, and whose `apply` job resizes only after approval.

- [ ] **Step 1: Write the workflow**

`.github/workflows/vm-scale.yml`:

```yaml
# Proposes a VM resize; never performs one unasked. The `apply` job carries
# `environment: vm-resize`, and its Azure credential's federated subject IS that
# environment -- so GitHub cannot mint a usable token until a reviewer approves.
# A bug in policy.rb cannot resize anything, because it cannot obtain a
# credential Azure will accept.
#
# See docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md and
# docs/runbooks/vm-scaling-setup.md.
name: VM scale

on:
  schedule:
    # GitHub's scheduler is best-effort and can run 10-20 minutes late under
    # platform load, so this means "you hear within roughly half an hour", not
    # fifteen minutes. Acceptable because nothing acts on its own.
    - cron: "*/15 * * * *"
  workflow_dispatch:
    inputs:
      target:
        description: "Size to resize to, or 'auto' for the policy engine's verdict"
        type: choice
        default: auto
        options: [auto, Standard_B1ms, Standard_B2s, Standard_B2ms]
      dry_run:
        description: "Do everything except the resize itself"
        type: boolean
        default: false

permissions:
  contents: read
  id-token: write
  issues: write
  actions: read

env:
  RG: MEZINEU
  VM: web
  LADDER: ops/vmscale/ladder.json
  BUDGET_CEILING_USD: "45"
  BASELINE_USD: "7.5"
  LOG_ISSUE_LABEL: vm-scaling-log
  HEALTH_URL: https://game.mezin.eu/up

jobs:
  observe:
    runs-on: ubuntu-latest
    outputs:
      verdict: ${{ steps.decide.outputs.verdict }}
      target: ${{ steps.decide.outputs.target }}
      apply: ${{ steps.decide.outputs.apply }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Authenticate to Azure (read-only identity)
        uses: azure/login@f5d393ae46f8fde4be8b75f32e3fc50e654ad0ca # v3.0.1
        with:
          client-id: ${{ secrets.AZURE_VMSCALE_READER_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Gather the load profile
        run: ./ops/vmscale/gather.sh > input.json

      - name: Decide
        id: decide
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          MANUAL_TARGET: ${{ inputs.target }}
        run: |
          set -euo pipefail
          ruby ops/vmscale/policy.rb < input.json > verdict.json
          cat verdict.json

          VERDICT=$(jq -r .verdict verdict.json)
          TARGET=$(jq -r '.target // empty' verdict.json)

          # A manual dispatch with an explicit size overrides the engine. This
          # is the documented scale-down path, and it uses the same gate.
          if [ -n "${MANUAL_TARGET:-}" ] && [ "${MANUAL_TARGET}" != "auto" ]; then
            VERDICT=manual
            TARGET="$MANUAL_TARGET"
          fi

          APPLY=false
          case "$VERDICT" in
            scale_up|scale_down|manual) APPLY=true ;;
          esac

          # A fifteen-minute cron against a persistent breach would queue a
          # fresh approval every fifteen minutes. At most one is ever pending.
          # A manual dispatch is always honoured -- it is the operator asking.
          if [ "$APPLY" = true ] && [ "$VERDICT" != manual ]; then
            WAITING=$(gh run list --workflow vm-scale.yml --status waiting \
                        --json databaseId --jq 'length')
            if [ "$WAITING" -gt 0 ]; then
              echo "an approval is already pending; not queueing a second"
              APPLY=false
            fi
          fi

          {
            echo "verdict=$VERDICT"
            echo "target=$TARGET"
            echo "apply=$APPLY"
          } >> "$GITHUB_OUTPUT"

      - name: Write the run summary
        run: |
          {
            echo "### VM scale — \`$(jq -r .verdict verdict.json)\`"
            echo
            echo "| | |"
            echo "|---|---|"
            jq -r '.evidence | to_entries[] | "| \(.key) | \(.value) |"' verdict.json
            echo
            jq -r '.reasons[] | "- \(.)"' verdict.json
          } >> "$GITHUB_STEP_SUMMARY"

      # Only when something is being proposed. A comment every fifteen minutes
      # would be 96 a day and nobody would read the one that mattered. The
      # per-run evidence lives in the step summary above; the raw metrics live
      # in Azure Monitor for 93 days, which is where analysis belongs anyway.
      - name: Record the proposal
        if: steps.decide.outputs.verdict != 'hold'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          ISSUE=$(gh issue list --label "$LOG_ISSUE_LABEL" --state open --limit 1 \
                    --json number --jq '.[0].number // empty')
          if [ -z "$ISSUE" ]; then
            echo "no open issue labelled $LOG_ISSUE_LABEL — see docs/runbooks/vm-scaling-setup.md"
            exit 1
          fi
          {
            echo "**\`$(jq -r .verdict verdict.json)\`** — $(jq -r .current verdict.json) → $(jq -r '.target // "—"' verdict.json)"
            echo
            jq -r '.reasons[] | "- \(.)"' verdict.json
            echo
            echo "[run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})"
          } | gh issue comment "$ISSUE" --body-file -

  apply:
    needs: observe
    if: needs.observe.outputs.apply == 'true'
    runs-on: ubuntu-latest
    environment: vm-resize
    concurrency:
      group: vm-scale-apply
      cancel-in-progress: false
    env:
      TARGET: ${{ needs.observe.outputs.target }}
      DRY_RUN: ${{ inputs.dry_run || false }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Authenticate to Azure (operator identity)
        uses: azure/login@f5d393ae46f8fde4be8b75f32e3fc50e654ad0ca # v3.0.1
        with:
          client-id: ${{ secrets.AZURE_VMSCALE_OPERATOR_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Re-verify the target
        run: |
          set -euo pipefail
          # The approval may be minutes or days old. Nothing from the proposal
          # is trusted; every check is made again here.
          jq -e --arg t "$TARGET" 'any(.[]; .size == $t)' "$LADDER" > /dev/null \
            || { echo "$TARGET is not on the allowlist in $LADDER"; exit 1; }

          CURRENT=$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv)
          echo "current=$CURRENT target=$TARGET"
          if [ "$CURRENT" = "$TARGET" ]; then
            echo "already $TARGET; nothing to do"
            echo "NOOP=true" >> "$GITHUB_ENV"
            exit 0
          fi

          # A target absent from this list would need a deallocate/start cycle
          # rather than a reboot. That is a different operation and must never
          # happen by surprise.
          az vm list-vm-resize-options -g "$RG" -n "$VM" --query '[].name' -o tsv \
            | grep -qx "$TARGET" \
            || { echo "$TARGET is not offered by this VM's current cluster"; exit 1; }

      - name: Resize
        if: env.NOOP != 'true' && env.DRY_RUN != 'true'
        run: az vm resize -g "$RG" -n "$VM" --size "$TARGET"

      - name: Wait for the app to answer
        if: env.NOOP != 'true' && env.DRY_RUN != 'true'
        run: |
          for attempt in $(seq 1 60); do
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" || true)
            if [ "$code" = "200" ]; then
              echo "up after ${attempt} attempt(s)"
              exit 0
            fi
            sleep 10
          done
          echo "$HEALTH_URL did not return 200 within ten minutes"
          exit 1

      - name: Record the outcome
        if: always()
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          ISSUE=$(gh issue list --label "$LOG_ISSUE_LABEL" --state open --limit 1 \
                    --json number --jq '.[0].number // empty')
          [ -n "$ISSUE" ] || exit 0
          gh issue comment "$ISSUE" --body \
            "Apply → \`${{ job.status }}\` (target \`$TARGET\`, dry-run \`$DRY_RUN\`, no-op \`${NOOP:-false}\`) · [run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})"
```

- [ ] **Step 2: Check the YAML parses**

```bash
ruby -ryaml -e 'YAML.unsafe_load_file(".github/workflows/vm-scale.yml"); puts "yaml ok"'
```

Expected: `yaml ok`.

- [ ] **Step 3: Commit and push the branch**

```bash
git add .github/workflows/vm-scale.yml
git commit -m "Propose resizes on a cron, apply them only after approval

One workflow with two jobs rather than a poller dispatching a second
workflow: GitHub refuses to create a run from a workflow_dispatch
triggered with GITHUB_TOKEN, and the workarounds are a PAT this
repository does not use or a GitHub App. A job carrying
environment: vm-resize pauses the run for approval and takes the
environment as its OIDC subject, which is what the design needs anyway.

observe declines to queue a second approval while one is waiting, so a
fifteen-minute cron against a persistent breach cannot pile up. The
apply job re-derives every check rather than trusting a proposal that
may be days old, and health-gates the result -- which is the whole
reason to route a manual operation through CI."
git push -u origin HEAD
```

- [ ] **Step 4: Smoke-test the observe job**

```bash
gh workflow run vm-scale.yml --ref "$(git branch --show-current)"
gh run watch
```

Expected: `observe` succeeds, the summary shows `hold` against live metrics, and **no `apply` job appears**. If `apply` appears on a quiet VM, the verdict logic is wrong — stop and investigate before proceeding.

- [ ] **Step 5: Smoke-test the gate, without resizing anything**

```bash
gh workflow run vm-scale.yml --ref "$(git branch --show-current)" \
  -f target=Standard_B2s -f dry_run=true
gh run watch
```

Expected: the run **pauses** with `apply` awaiting approval and a notification arrives. Approve it, and the job should authenticate as the operator identity, pass the allowlist and cluster checks, skip both the resize and the health poll because `dry_run` is true, and comment on the log issue.

This is the one test that proves the whole guarantee end to end: the operator credential was minted only after a human approved, and nothing was resized.

---

### Task 12: Document it, and verify the whole suite

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the section to `CLAUDE.md`**

Insert immediately before the `## Deployment` heading:

```markdown
## VM scaling proposals

`.github/workflows/vm-scale.yml` watches the production VM's load every fifteen minutes and
**proposes** a resize; it never performs one unasked. `ops/vmscale/gather.sh` makes every `az`
call and prints one JSON document; `ops/vmscale/policy.rb` is a pure function from that document
to a verdict, with no network, no shelling out and no clock — which is why it is testable from
fixtures and why `spec/ops/vmscale_policy_spec.rb` needs `spec_helper` rather than `rails_helper`.

Two things about it are easy to get wrong:

- **The primary trigger is CPU *credit depletion*, not CPU percentage.** On a burstable SKU 100%
  CPU is the product working — this VM peaks at 99% most days and spends three credits of 288 a
  week. Running the bank down is what throttles it to a 20% baseline, and at that point the site
  is unusable while `Percentage CPU` reports a serene 20%. A threshold on CPU% fires constantly
  and means nothing.
- **The approval is the authorisation, not a check in the code.** The `apply` job carries
  `environment: vm-resize`, and the Azure identity it uses has exactly one federated credential
  whose subject is that environment. GitHub does not mint a token for a protected environment
  until a reviewer approves, so a bug in `policy.rb` cannot resize anything — it cannot obtain a
  credential Azure will accept. That guarantee is configuration, not code: `docs/runbooks/vm-scaling-setup.md` §5
  re-verifies it, and it is worth re-running after any change to the identities or the environment.

Scaling down uses the same workflow and the same gate — dispatch it manually with a `target`.
`az vm resize -g MEZINEU -n web --size Standard_B1ms` from a laptop always works too and nothing
here can intercept it. The 48-hour cooldown suppresses **proposals** only; it is not a lock.

Design and deferred alternatives (blue/green, managed Postgres, and why the second is a
prerequisite for the first) are in
`docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md`.
```

- [ ] **Step 2: Run the full RSpec suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
DATABASE_URL="sqlite3:$(mktemp -d)/test.sqlite3" bundle exec rspec
```

Expected: 0 failures, and the example count up by 41 from the pre-change baseline. The
`DATABASE_URL` override keeps a parallel session's suite from locking `db/test.sqlite3`.

Record the actual number — do not quote the figure in `CLAUDE.md`, which has been wrong four
times.

- [ ] **Step 3: Run the acceptance suite**

```bash
bundle exec cucumber
```

Expected: **238 scenarios, 2386 steps, unchanged.** Nothing in this branch touches `features/`
or any code path they exercise, so any movement at all is a signal to stop and look.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Document the VM scaling proposer

The two things easy to get wrong: the trigger is credit depletion
rather than CPU percentage, and the approval IS the authorisation
rather than a check the code performs."
```

- [ ] **Step 5: Open the pull request**

```bash
gh pr create --fill --base master
```

Include in the body: the RSpec count measured in Step 2, the Cucumber result from Step 3, and a
note that `docs/runbooks/vm-scaling-setup.md` §1–5 must be run before the workflow can do
anything — until then `observe` fails at `azure/login` on every scheduled run.

---

## Notes for the executor

- **Task 10 blocks Task 11's verification.** The plan can be implemented straight through, but
  Task 11's Steps 4 and 5 cannot pass until the repository owner has run the runbook.
- **Example counts in this plan are cumulative and exact** (5, 9, 14, 18, 24, 32, 38, 41). If a
  task's run reports a different number, an example was miscopied — find it before moving on.
- **The synthetic fixtures live in the spec file, not on disk.** The design document's §5 names
  eight cases; seven of them are built by mutating a deep copy of the one real captured fixture.
  That is deliberate: hand-written JSON drifts away from what Azure actually returns, and the
  whole value of the real fixture is that it does not.
