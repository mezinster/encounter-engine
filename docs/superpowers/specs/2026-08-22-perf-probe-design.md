# The performance probe — design

**Date:** 2026-08-22
**Status:** design approved in chat; implementation plan not yet written
**Related:** `docs/superpowers/specs/2026-08-21-load-testing-design.md`,
`docs/runbooks/load-test.md`, `.github/workflows/deploy.yml`,
`.github/workflows/vm-scale.yml`

## 1. What this is

An **instrument you invoke**, not a gate that runs on a schedule. It answers
"how does this host shape, with this game, at this arrival rate, actually
perform?" — and records the answer in a form that can still be compared to
another answer six months later.

It exists because the load-testing harness built on 2026-08-21 works but is
driven by hand, and because its first real run showed that the same question
has very different answers depending on parameters nobody was recording.

### 1.1 The measurement that motivated it

Two runs on 2026-08-21, same application, same 120 teams, same
`Standard_B1ms`:

| arrival | p95 | errors | CPU |
|---|---|---|---|
| over 22 minutes | **196 ms** | 0% | under 10% |
| over 30 seconds | **5 860 ms** | 0% | aborted at threshold |

Nothing failed in either. The only difference is how fast the teams arrived —
91 bcrypt logins in half a minute is what a real encounter game does at the
whistle, and it is thirty times more expensive than the same teams trickling
in. A record reading `120 teams → 196 ms` would have been actively misleading
within a month.

That is the whole argument for this tool: a number is worthless without the
parameters that produced it.

### 1.2 Non-goals

* **No cron.** Nothing runs unattended. This is a probe, not a monitor.
* **No pass/fail gate.** Thresholds stay as *observations*; an aborted run is a
  result, not a build failure. A red build caused by someone else's slow query
  is a nuisance that gets muted, and a muted tool is a dead one.
* **No resizing.** See §3.1.
* **No replica environment.** See §3.1.

## 2. What already exists

Nothing here is built from scratch. The design is mostly wiring.

* `LoadTest::Seeder` clones a real game and creates N teams part-way through
  it in seconds, with an advisory lock preventing concurrent seeds, and a
  teardown that deletes explicitly and proves the tables are restored.
* `load_test/main.js` drives `/login` and `/play/:id` with `ramp` and `hold`
  phases, an env-driven plateau ladder, and an oversubscription guard.
* `load_test/provision.sh` stands up a throwaway generator in westeurope with
  the NSG closed to the caller's `/32`, and destroys the whole resource group.
  Verified end to end on 2026-08-21: 79 s to create, cloud-init installs k6,
  six resources removed on destroy with no orphans.
* `.github/workflows/deploy.yml` already reaches production from a runner:
  OIDC to Azure, a just-in-time NSG rule for the runner's IP, SSH, and the rule
  deleted in the same job.
* `ops/vmscale/gather.sh` already reads the VM's size and CPU-credit balance
  from Azure, for the scaling policy.

## 3. Decisions

### 3.1 The tool never changes the host shape

Three ways to compare shapes were considered.

**Resize production between runs**, reusing `vm-scale.yml`'s gated resize —
rejected. It gives an on-demand answer on real hardware with the real database,
and the machinery exists behind an approval environment. But every resize
reboots the live site, and a tool whose normal operation restarts production is
a tool people become reluctant to run.

**A replica at the target size** — rejected. It never touches production, but
needs the whole stack plus a realistic dataset, and a replica with an empty or
stale database does not behave like the live one, which is the thing being
measured.

**Observational only** — chosen. The probe records the shape it finds and never
changes it. Comparison across shapes emerges as the host is resized for other
reasons, which `vm-scale.yml` already proposes and gates.

The cost is real and should be stated: **this tool cannot answer "what would
B2s give us" before you are on B2s.** It answers "what did each shape give us,
whenever we were on it." Accepting that is what keeps it safe enough to run
casually, and running it casually is what fills the record.

### 3.2 The generator is selectable, and every run measures its own baseline

The generator is an input: `runner` (a GitHub-hosted runner, free, no Azure
resources, region uncontrolled) or `vm` (the existing `provision.sh`, same
region as the app, pennies per run).

A fixed generator was considered, to keep results comparable. Making it
selectable instead is better, because the comparability problem has a cleaner
solution than restricting the tool:

**Every run measures its own network baseline before applying any load** — a
handful of warm-connection requests to `/up` — and records it. Comparisons then
work on app time rather than wall time.

The numbers this matters by, measured on 2026-08-21: a warm request from a
laptop in Georgia cost **94 ms**; the same request from a VM in westeurope cost
**13.5 ms**; the application's own reported time was **16–17 ms**. Without a
recorded baseline, a run from a runner and a run from a same-region VM are
simply not the same measurement, and nothing in a k6 summary would tell you.

**If the baseline measurement fails, the run stops before applying load.** A
result that cannot be compared to anything is not worth the traffic.

### 3.3 Results are committed to the repository

Each run appends one small JSON record to `docs/perf/results/` and commits it;
the full k6 output goes to a build artifact.

Build artifacts alone were rejected: they expire — ninety days by default, four
hundred at most — so a comparison spanning a year would silently lose its early
half. Building a comparison tool whose history evaporates is worse than not
building one, because the gap is invisible.

An issue comment per run was rejected: durable and readable, but prose cannot
be compared mechanically, and there would be no way to chart it later without
scraping.

The repository is public. The record holds latency numbers, a game id, a host
size and a commit SHA. Nothing sensitive. It is commit noise on `master`, which
is the accepted price of a durable, diffable, greppable history that lives
beside the code that produced it.

**It arrives as a pull request, not a direct push** (revised 2026-08-27). This
section said "commits it" and the workflow duly ran `git push`, which `master`
rejects: pull requests are required, `enforce_admins` is on, and there is no
bypass allowance. The rejection would have landed *after* the cohort was seeded
and the load run — the most expensive point in the workflow at which to discover
it — and would have thrown away the one artefact the run exists to produce. The
record now goes to `perf-record/<run_id>` and `gh pr create` opens the pull
request, with the record itself quoted in the body so it is readable without
checking the branch out. The cost is a merge click; the benefit is that a
protection change on `master` can no longer silently destroy a completed probe.

## 4. Inputs

`workflow_dispatch` only.

| input | type | notes |
|---|---|---|
| `source_game` | game id | the "different games" axis |
| `teams` | integer | cohort size; for `ramp`, at least the top plateau — `main.js` already refuses otherwise |
| `scenario` | `ramp` / `hold` / `stampede` | which question is being asked |
| `stampede_window` | duration, default `30s` | `stampede` only: how long the teams take to arrive |
| `generator` | `runner` / `vm` | free and fast, or same-region and faithful |
| `note` | free text | "before the Postgres tuning" |

`stampede` does not exist yet — see §8.

**`stampede_window` added 2026-08-27**, after the first successful probe run
([33066075206][r2]) reproduced the login stampede independently: p95 **5650 ms**
against the 5860 ms measured by hand on 2026-08-21, zero errors, every check
passing. `main.js` had read `STAMPEDE_WINDOW` since it was written and nothing
could set it, so the axis this whole document is organised around — *the same
120 teams differ by 30× depending only on how fast they arrive* — was the one
axis the workflow could not vary.

It is also the cheapest test of why. A bcrypt-cost-12 verify is ~254 ms of
single-core CPU, and 120 teams over 30 s is 4 logins/s, so arrivals alone offer
≈1.02 cores to a 1-vCPU host. Utilisation at ~1.0 produces exactly what was
observed: latency climbing, nothing failing. If that is right, widening the
window divides the arrival rate and p95 should collapse — and where it crosses
2 s is the operationally useful number, the arrival rate a game night may
actually use.

[r2]: https://github.com/mezinster/encounter-engine/actions/runs/33066075206

## 5. The record

```json
{ "at": "2026-08-21T20:15Z", "note": "first stampede",
  "host":      { "size": "Standard_B1ms", "vcpu": 1, "ram_gib": 2,
                 "cpu_credits_remaining_start": 287.9,
                 "cpu_credits_max_7d": 288.0 },
  "generator": { "kind": "vm", "region": "westeurope",
                 "baseline_warm_ms": 13.5 },
  "game":      { "id": 4, "levels": 71 },
  "run":       { "scenario": "stampede", "teams": 120 },
  "app":       { "sha": "276f55a" },
  "result":    { "p50_ms": 2650, "p95_ms": 5860, "max_ms": 7600,
                 "error_rate": 0.0, "outcome": "aborted",
                 "abort_reason": "http_req_duration" } }
```

**Record everything that could explain a difference, at the moment of the
run**, because none of it can be reconstructed afterwards. Two fields earn
particular mention:

* **The two credit fields, and why there are two.** "CPU Credits Remaining" is
  an absolute **count**, not a percentage — a `Standard_B1ms` banks up to 288,
  so a reading of 287.9 is a full tank rather than an alarming number. Different
  sizes have different ceilings, so a bare count cannot be compared across
  shapes; `cpu_credits_max_7d` is the denominator that lets a reader normalise.
  `ops/vmscale/policy.rb` takes the same approach under the same name.

  *(This design originally called the field `credits_pct_start`, which was
  simply wrong — the name asserted a percentage the metric does not provide, and
  only running it revealed that.)*

  The reason to record it at all: this is a burstable VM,
  the same load against a full credit bank and a drained one gives different
  answers, and a k6 summary knows nothing about it. Without this field, two
  runs a month apart could differ by host shape, by game, by code — or purely
  by how idle the machine happened to be beforehand.
  `ops/vmscale/gather.sh` already reads it.
* **`app.sha`** is what separates "the host got slower" from "we shipped
  something".

**`generator.region` is `null` for a runner, and that is correct rather than a
gap.** GitHub does not reliably expose which region a hosted runner is in, and a
field that is sometimes a fact and sometimes a guess is worse than one that is
honestly absent. `baseline_warm_ms` is the operative value in both cases — it is
measured, not asserted, and it is what comparisons actually use.

**`cpu_credits_remaining_start` assumes a burstable host.** All three shapes on
`ops/vmscale/ladder.json` are B-series, so it is always available today. If the
ladder ever gains a non-burstable size the field becomes `null` there, and its
absence is itself information: a shape with no credit bank cannot exhibit the
burst-then-throttle behaviour the field exists to explain.

## 6. Seeding and teardown

The workflow reuses `deploy.yml`'s production-access pattern unchanged: OIDC to
Azure, a just-in-time NSG rule for the runner's IP, SSH, rule deleted in the
same job. No new access path and no new secret.

**That last sentence was wrong, and §5's host facts are why** (corrected
2026-08-27). `ee-deploy-oidc` holds exactly one role assignment — Network
Contributor on `webNSG` — because it is the identity that can open port 22, and
it is deliberately unable to do anything else. `host_facts.sh` needs
`Microsoft.Compute/virtualMachines/read` and metrics read on `web`, which that
identity does not have and should not be given. In run 33062376105 its first
`az vm show` returned `AuthorizationFailed` while the step reported **success**
(`script | tee file` under `bash -e` exits with `tee`'s status), so the facts
this section calls load-bearing had never once been collected.

The probe therefore uses **two** identities: `ee-vmscale-reader-oidc`, which
already holds Reader and Monitoring Reader on `web` for `vm-scale.yml` and
nothing else, gathers the host facts *before* the NSG is touched — they are API
reads and need no SSH hole — and `ee-deploy-oidc` takes over for everything
after. The reader gained one federated credential for
`:environment:production` alongside its existing `:ref:refs/heads/master`; no
role assignment changed, and neither identity is logged in while the other's
work happens.

`az vm list-skus` was dropped rather than authorised. It reads at *subscription*
scope, so no VM-scoped identity can ever call it, and the two numbers it fetched
— vCPU and RAM for the current size — are already committed in
`ops/vmscale/ladder.json`, the same file `policy.rb` decides against. A size
absent from the ladder yields `null`, on this document's own reasoning about the
credit fields: a shape nobody has costed is exactly the shape a reader should be
told nothing about.

**Still unresolved: the `vm` generator.** `load_test/provision.sh` creates a VM
in the `encounter-loadgen` resource group, and `ee-deploy-oidc` has no rights
there either. `generator: runner` is the default and is unaffected; the `vm`
path has never run and will fail on authorisation when it first does.

It generates its own cohort id and passes it as `LOAD_TEST_CONFIRM`.

**This is a deliberate weakening of a safety property and is recorded as such.**
`LOAD_TEST_CONFIRM` exists so a human states the cohort id before hundreds of
production accounts are created. Here the `workflow_dispatch` is that
statement — only a user with write access can trigger it, and the inputs are
recorded in the run. What it is *not* is the same protection, because a re-run
button repeats it with nobody retyping anything. Two things make the trade
acceptable: seeding now takes seconds and is fully reversible, and
`Seeder.teardown!` independently validates the id against the cohort actually
present, so a stale id cannot destroy a live one. The guard's purpose was
always to stop an accident; a deliberate dispatch is not one.

**Teardown runs under `if: always()`** — cohort and generator, on every exit
path including cancellation. If teardown itself fails the workflow fails
loudly and prints the recovery command with the cohort id, because a silent
failure there leaves hundreds of accounts in production. `load_test:status` is
the confirmation.

## 7. Failure handling

A failed run is data. The record is written either way, carrying
`outcome: completed | aborted | errored` and, where relevant, `abort_reason`.

The two aborts of 2026-08-21 are the clearest illustration: one of them is the
only measurement of the login stampede in existence, and a design that only
recorded successes would have thrown it away.

The single exception is §3.2's: a failed baseline stops the run before any load
is applied.

## 8. What this depends on that does not exist yet

**A `stampede` scenario.** `main.js` has `ramp` and `hold`. The measurement
that motivated this whole tool — 120 teams arriving in 30 seconds — was
produced by *accident*, by passing a single-plateau ladder that happened to
ramp 0→120 in the executor's 30-second stage. That is not a scenario anyone
would reproduce deliberately from the current inputs.

Since §1.1 argues the stampede is the question that actually decides whether a
game night works, the probe should be able to ask it directly. This is a small
piece of work — one scenario block and an env knob — but it is a prerequisite,
not a follow-up, and it should land before or with the workflow.

## 9. Open questions

1. ~~Whether the workflow should carry an `environment:` approval gate as
   `vm-scale.yml`'s apply job does.~~ **Answered 2026-08-27, and not on the
   merits.** The question was framed as a policy choice about seeding hundreds
   of production rows; it is not a choice at all. §6 above says the workflow
   "reuses `deploy.yml`'s production-access pattern unchanged … no new access
   path and no new secret" — true only *with* `environment: production`, which
   the implementation omitted. Every secret involved (`SSH_PRIVATE_KEY`,
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) is scoped to
   that environment, and `ee-deploy-oidc` trusts exactly one federated subject,
   ending `:environment:production`. Outside it, `secrets.X` is the empty string
   and Azure issues no token.

   The first dispatch, [run 33059853248][r1], failed at `Load the deploy SSH
   key` with *"The ssh-private-key argument is empty"* — the first step that
   bothered to validate its input, four steps past the actual mistake. Nothing
   was seeded and no NSG rule was opened, so the run was inert; the red
   "TEARDOWN DID NOT COMPLETE" it printed was an alarm about a cohort that never
   existed, since fixed. The gate is now present, the approval click is its
   price, and it is charged once per probe.

   [r1]: https://github.com/mezinster/encounter-engine/actions/runs/33059853248
2. Whether `hold` is worth supporting at all until a run gets close to a real
   ceiling. At 10% CPU the credit bank cannot drain, so the phase currently has
   nothing to observe.
3. How the accumulated records get read. A directory of JSON is greppable and
   diffable, which is enough to start; whether it eventually wants a summary
   table or a chart is a question for when there are twenty of them, not now.
