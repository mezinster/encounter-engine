# Performance records

One JSON file per run of the **performance probe**
(`.github/workflows/perf-probe.yml`). The probe is an instrument you invoke, not
a monitor on a schedule, and it never resizes anything — it records the host
shape it finds.

Design: `docs/superpowers/specs/2026-08-22-perf-probe-design.md`

**New to this?** [`docs/manual/performance.en.md`](../manual/performance.en.md) explains what
`ramp`, `stampede` and `hold` are in plain language, and why the same 120 teams can be twenty
times slower depending only on how fast they arrive. ([по-русски](../manual/performance.ru.md))

## Why a record rather than a number

On 2026-08-21, by hand, against production on a `Standard_B1ms`:

| arrival | p95 | errors | CPU |
|---|---|---|---|
| 120 teams over 22 minutes | **196 ms** | 0% | under 10% |
| 120 teams over 30 seconds | **5 860 ms** | 0% | aborted at threshold |

Same application, same box, same team count. Nothing failed in either — 91
bcrypt logins landing together on one vCPU is the entire difference.

A note reading `120 teams → 196 ms` would have been actively misleading within a
month. So every parameter that could explain a difference is captured at the
moment of the run, because none of it can be reconstructed afterwards.

## What the records say so far

Three runs on 2026-08-27, all `vm` generator, all 120 teams on the same
`Standard_B1ms`, varying only `run.stampede_window`:

| window | logins/s | p50 | p90 | p95 | outcome |
|---|---|---|---|---|---|
| `30s`  | 4 | 2229 ms | — | **8047 ms** | aborted at 32 s |
| `60s`  | 2 | 27.5 ms | 57.8 ms | **309 ms** | completed, 5m30s |
| `120s` | 1 | 28.4 ms | 59.4 ms | **318 ms** | completed |

**Halving the arrival rate made it 26× faster, and halving it again did
nothing** — 309 ms against 318 ms. That flatness is the finding. Below the line
the host barely notices the crowd; above it, work arrives faster than one vCPU
can retire it and the queue does the rest. Between 2 and 4 logins per second
this host crosses it.

A bcrypt verify at cost 12 measures ~254 ms of single-core CPU, so 4 arrivals/s
offers ≈1.02 cores to a machine that has one. The prediction and the measurement
agree, and the percentile shape says the same thing a third way: in the healthy
runs `p90` is ~58 ms and `p95` is ~310 ms, and the ~8% of requests that are
logins are exactly the slice between them. The password check is visible in the
distribution.

**Operationally: 120 teams need about a minute to arrive, not thirty seconds** —
roughly two arrivals per second. `docs/manual/performance.en.md` says this in
plain language for whoever is running the game night
([по-русски](../manual/performance.ru.md)).

One caveat remains attached to those numbers, and one has since been answered.
The exact edge is still not pinned: 60 s cleared the 2 000 ms threshold with a
6× margin, so the real cliff sits nearer 30–40 s than 60. The other — that
neither passing run lasted long enough to touch the credit bank, so nothing
there spoke to hour two of a real game — is what the next section is about.

## What forty minutes of play costs: nothing

`hold` ran on 2026-08-27, 120 teams, the full 40 minutes, same `Standard_B1ms`,
`vm` generator (workflow run 33109290689). It **ran to its planned end** and
both latency thresholds passed:

| | |
|---|---|
| p50 / p90 / p95 | 29.0 ms / 49.1 ms / **371.5 ms** (threshold p95 < 2 000) |
| HTTP failures | **0.29%** (threshold < 2%) |
| throughput | 3.68 req/s, 4 241 iterations |
| CPU credits | **min 287.5 of 288**, ended 288.0 |
| CPU, steady state | **9–13%**, against a 20% baseline |
| available memory | 830–870 MB, flat |

**The credit bank is not the constraint at this load.** A `Standard_B1ms` earns
at a 20% baseline and this run sat at roughly half of it, so the machine was
*accruing* credits for most of the 40 minutes rather than spending them. Memory
did not drift either. Hour two is not where the risk is — the whistle is.

That also confirms the arrival model from the other direction: 3.68 req/s is the
~3.5 req/s the harness design predicted for 120 teams playing steadily.

### The one breach is the run's own startup

`checks` came in at 98.97% against a `rate>0.99` threshold — short by three
checks. The 89 failures were not spread evenly:

| check | passed | failed | |
|---|---|---|---|
| `logged in` | 120 | **22** | **84%** |
| `on the level screen` | 4 254 | 33 | 99% |
| `answer accepted by the app` | 4 202 | 34 | 99% |

142 login attempts for 120 teams. `load_test/main.js` caches one login per VU
and retries when it fails, so every team did get in — but 22 attempts did not.

**`HOLD` is `constant-vus`, which starts all 120 VUs simultaneously.** That is a
*zero-second* arrival window: narrower than any stampede in the table above, and
the 30 s one already aborted at p95 8 047 ms. Azure agrees about the timing —
across the whole 40 minutes exactly one five-minute bucket touched the credit
bank (the first, at 26.2% average CPU); every bucket after it reads 9–13%.

The percentile shape says it a third way. This run's **p90 of 49 ms is lower
than either healthy stampede run** (57.8 ms and 59.4 ms) while its p95 is higher
(371 ms against 309 and 318). A cleaner body with a fatter tail is what a
startup spike looks like when it is averaged into a whole-run aggregate.

**So this is a harness defect, not a product finding.** `hold` is meant to
measure steady state and is currently paying the stampede toll on the way in,
then averaging it into the result. It needs a warm-up that the measurement
excludes — a short ramp to `TEAMS`, or a `startTime` offset on the measured
phase. Until then, read a hold run's `p95` as a ceiling and its `p90` as the
truth.

**The record for this run is a version-2 record and says `"outcome": "aborted"`.**
It was not. That wording is the defect version 3 exists to fix — see `schema`
below.

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

**`host.cpu_credits_remaining_end` and `host.cpu_credits_min_during`** (v3) —
what the run *cost*, as opposed to what the bank held when it began. Two
readings and not one, because a bank that dipped during the run and recovered by
the end reads as untouched if you only look at the end: on the hold run above,
`_end` is 288.0 and `_during` is 287.5, and the second is the one that shows the
login burst happened at all. `cpu_credits_window` records how far back the
minimum was taken, since a window that stopped short of the run's own start
would report the calm after the burst as the whole story.

**`app.sha`** separates "the host got slower" from "we shipped something".

**`run.duration_s`** (v3) — how long k6 actually ran. This is the field that
separates *cut short at 32 seconds* from *ran its planned 40 minutes and
breached a threshold at the end*, and nothing before version 3 carried it:
establishing it for the hold run above meant reading the workflow log by hand
the following day, and Actions logs age out.

**`result.outcome`** is `completed` or `errored`, and it answers exactly one
question: did this run produce a measurement at all. `errored` means k6 wrote no
summary — a crash, a startup guard refusing, an unreachable host. A failed run
is data; the two aborts of 2026-08-21 are the most valuable measurements taken
so far, and one of them is the only record of the login stampede in existence.

**In version 2 `outcome` also claimed to know whether a run had been cut short,
and it could not.** It was derived as "was any threshold crossed", which is a
different question. `Perf::BuildRecord` is a pure function of a k6 summary, and
k6 writes a summary both for a run that finished and for one `abortOnFail`
killed mid-flight — nothing inside distinguishes them. Read `"aborted"` on any
version-1 or version-2 record as **"some threshold was crossed"** and nothing
more, then reach for the run's own log if you need to know which happened.

**`result.thresholds_crossed`** (v3) — the list of metrics that breached, `[]`
when none did, and `null` when there was no measurement to breach. A list rather
than version 2's single `abort_reason`, because a run can cross more than one
and the first one alphabetically is not the interesting one. It is also what
makes a *passing* threshold visible: the hold run crossed `checks` while
satisfying `http_req_duration` and `http_req_failed` with a five-fold margin,
and `"abort_reason": "checks"` destroyed that half of the story.

## Reading them

A directory of JSON is greppable and diffable, which is enough to start:

```bash
jq -r '[.at, .host.size, .run.scenario, .run.teams,
        .run.stampede_window     // "-",
        .run.duration_s          // "-",
        .result.p95_ms           // "-",
        .generator.baseline_warm_ms // "-",
        .result.outcome,
        ((.result.thresholds_crossed // ["?"]) | join(",") | if . == "" then "-" else . end)]
       | @tsv' docs/perf/results/*.json | column -t
```

**Every `// "-"` there is load-bearing, not decoration.** `column -t` splits on
runs of whitespace, so a genuinely null field — and several are null by design,
including the deliberately-nulled `baseline_warm_ms` on the 13:47Z record —
collapses and silently shifts every column after it one place left. A record
that reads as belonging to the wrong run is the failure this directory exists to
prevent, so it must not be reachable by pasting the recipe this file supplies.
A `-` also distinguishes *not applicable* from `?`, which marks a field the
record's own version predates.

Compare like with like: same scenario and team count when comparing host shapes,
same host when comparing games, and subtract the baseline either way.

**`run.stampede_window` is in that list for the reason the table at the top of
this file exists.** Its two rows — 196 ms and 5 860 ms — are the same 120 teams
on the same host, differing by nothing but how long they took to arrive. It is
`null` by design for `ramp` and `hold`, which pace themselves — there it means
"not applicable", not "unmeasured".

## `schema`

Every record says which version of this format wrote it. **A record with no
`schema` key at all is version 1.**

| version | what changed |
|---|---|
| 1 | the original shape: `run` carries `scenario` and `teams` only |
| 2 | adds `run.stampede_window` (2026-08-27) |
| 3 | `result.abort_reason` → `result.thresholds_crossed` (a list); `result.outcome` stops claiming a run was cut short; adds `run.duration_s` and the `host.cpu_credits_*` readings taken after the run (2026-08-28) |

It is one integer and it earns its place immediately, because absence is
ambiguous in a way that is entirely silent. On a **stampede** record,
`"stampede_window": null` could mean the run genuinely had no arrival window, or
that the record predates the field — and only a reader who happens to know the
field arrived on 2026-08-27 can tell them apart. A directory whose meaning
depends on remembering its own history is the thing this format exists to avoid.

So, reading older records:

```bash
# version-1 records, which is where the ambiguity lives
jq -r 'select((.schema // 1) == 1) | [.at, .run.scenario, .result.p95_ms] | @tsv' \
   docs/perf/results/*.json
```

Every version-1 **stampede** ran a `30s` arrival window, because nothing could
set `STAMPEDE_WINDOW` before the input existed. That is an inference from the
code of the day rather than something the record states — which is exactly the
kind of inference a later reader should not have to make unaided, and the reason
the version is now stamped rather than implied.

**Version 3 exists because a field can go stale without ever changing.**
`outcome` never lied about a stampede: those thresholds carry `abortOnFail`, so
a crossed one really did cut the run short. `hold` then arrived with
`abortOnFail: false` — a change in `load_test/main.js`, not in the record format
— and from that day `"aborted"` was unreachable as a true description of a hold
run, while still being the value written. Nothing failed. The first hold run
ever taken was filed under a word that could not apply to it.

That is the argument for `duration_s` being a *measurement* rather than an
inference. Teaching `Perf::BuildRecord` which thresholds abort which scenarios
would have worked, and would have put that policy in two files free to drift
apart in silence — which is the failure this whole format exists to prevent.

**Bump `Perf::BuildRecord::SCHEMA` when a field is added, removed, or changes
meaning; leave it alone for a refactor.** A spec pins the constant to a literal
so that bumping it is a decision rather than an accident, and the failure of that
example is the prompt to add a row to the table above.
