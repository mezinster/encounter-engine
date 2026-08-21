# Performance records

One JSON file per run of the **performance probe**
(`.github/workflows/perf-probe.yml`). The probe is an instrument you invoke, not
a monitor on a schedule, and it never resizes anything — it records the host
shape it finds.

Design: `docs/superpowers/specs/2026-08-22-perf-probe-design.md`

## Why a record rather than a number

On 2026-08-21, against production on a `Standard_B1ms`:

| arrival | p95 | errors | CPU |
|---|---|---|---|
| 120 teams over 22 minutes | **196 ms** | 0% | under 10% |
| 120 teams over 30 seconds | **5 860 ms** | 0% | aborted at threshold |

Same application, same box, same team count. Nothing failed in either — 91
bcrypt logins landing together on one vCPU is the entire difference.

A note reading `120 teams → 196 ms` would have been actively misleading within a
month. So every parameter that could explain a difference is captured at the
moment of the run, because none of it can be reconstructed afterwards.

## The fields that are not obvious

**`generator.baseline_warm_ms`** — what this run's network cost, measured before
any load. The generator is selectable, so a result from a GitHub runner and one
from a westeurope VM are not the same measurement: a warm request cost 94 ms
from a laptop in Georgia and 13.5 ms from a VM in the app's own region, against
an application time of 16–17 ms. **Subtract it before comparing runs.**

**`generator.region`** is `null` for a runner. GitHub does not reliably expose
which region a hosted runner is in, and a field that is sometimes a fact and
sometimes a guess is worse than one that is honestly absent. `baseline_warm_ms`
is the operative value in both cases — it is measured, not asserted.

**`host.cpu_credits_remaining_start` and `host.cpu_credits_max_7d`** — this is a
burstable VM. The same load against a full credit bank and a drained one gives
different answers, and a k6 summary knows nothing about it. Without these, two
runs a month apart could differ by host shape, by game, by code — or purely by
how idle the machine happened to be beforehand.

There are two because the metric is an absolute **count**, not a percentage: a
`Standard_B1ms` banks up to 288, so 287.9 is a full tank. Different sizes have
different ceilings, so the 7-day maximum is the denominator that makes a count
comparable across shapes.

Both are `null` when Azure has no datapoint — never zero. Absent data must not
read as reassuring: a missing reading is unknown, and zero would mean
"exhausted", the opposite conclusion.

**`app.sha`** separates "the host got slower" from "we shipped something".

**`result.outcome`** is `completed`, `aborted` or `errored`. A failed run is
data — the two aborts of 2026-08-21 are the most valuable measurements taken so
far, and one of them is the only record of the login stampede in existence.

## Reading them

A directory of JSON is greppable and diffable, which is enough to start:

```bash
jq -r '[.at, .host.size, .run.scenario, .run.teams,
        .result.p95_ms, .generator.baseline_warm_ms, .result.outcome] | @tsv' \
   docs/perf/results/*.json | column -t
```

Compare like with like: same scenario and team count when comparing host shapes,
same host when comparing games, and subtract the baseline either way.
