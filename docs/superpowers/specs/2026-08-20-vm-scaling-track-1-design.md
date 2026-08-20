# Vertical scaling by proposal — Track 1

**Status:** design, approved 2026-08-20.
**Scope:** Track 1 of three. Tracks 2 and 3 are costed, deferred, and described in §9 — this
document builds none of them.

---

## 0. The gap

The app runs on one Azure VM, `web` in resource group `MEZINEU`, a `Standard_B1ms` — 1 vCPU,
2 GiB. If encounter-engine gets popular enough to exhaust it, there is currently no mechanism at
all: no alert, no proposal, no procedure. The first signal would be players reporting that the
site is slow, and the first response would be an unrehearsed manual resize.

Track 1 closes that, and does exactly that much. It watches, it proposes, and a human decides.

It is worth saying plainly what it is *not* for. The measured baseline in §1 says this VM is
nowhere near a ceiling, and the honest cheapest fix for a capacity problem that has not arrived is
to buy one rung of headroom (`B1ms` → `B2s`, +$17.52/month) and never resize at all. Track 1's real
product is therefore **not the resize**. It is the decision log: a recorded verdict every fifteen
minutes, accumulating into the load history that will one day say whether Track 2 is justified.
Building anything more elaborate before that history exists is guessing.

---

## 1. The measured baseline

Seven days to 2026-08-20, from Azure Monitor:

| Metric | Average | Extreme |
|---|---|---|
| `Percentage CPU` | 5.0% | max 99.2% |
| `Available Memory Bytes` | 878 MB | **min 472 MB** of 2 GiB |
| `CPU Credits Remaining` | 288.0 | **min 285.1** of 288 |

Two readings follow, and both shape the thresholds in §2.

**The CPU spikes cost nothing.** A burstable B-series VM banks unused CPU as credits and spends
them to burst. The bank has moved by 3 credits out of 288 in a week, which means every spike —
deploys, translation runs, wal-g pushes — was absorbed for free. A threshold on `Percentage CPU`
would have proposed a resize several times this week, each time wrongly.

**Memory is the axis with an actual floor.** 472 MB free at the worst observed moment, on a host
that also carries the Postgres accessory, kamal-proxy, danted and the APRS forwarders. This is the
number that will run out first, and `config/deploy.yml` already argues against itself on this
basis — `builder.remote: false` and the 64 MB proxy body cap both exist because of it.

The whole B ladder up to `Standard_B20ms` is currently available as an **in-place** resize
(`az vm list-vm-resize-options`), so a scale event is a ~90-second reboot, not a deallocate/start
cycle. The public IP is **Static** (`webPublicIP`), so it survives either.

---

## 2. Decisions

| | |
|---|---|
| **V1** | **Nothing resizes without a human approval**, enforced by environment-scoped OIDC — by *capability*, not by code. |
| **V2** | **Two identities.** A read-only poller identity, and a resize identity that only exists behind the reviewer gate. |
| **V3** | The policy engine is a **pure function**: JSON in, verdict out. No network, no `az`, no ambient clock. |
| **V4** | The engine is **stateless**. Cooldown comes from the Azure Activity Log; history from Azure Monitor and one GitHub Issue. |
| **V5** | The primary scale-up trigger is **CPU credit depletion**, not CPU percentage. |
| **V6** | **Available memory is a first-class trigger**, with its own threshold. |
| **V7** | The **budget ceiling is an input**, and breaching it yields a distinct verdict — `at_budget_ceiling`, never `scale_up`. |
| **V8** | On a breach the poller **comments and queues**; the run sits pending. It never executes. |
| **V9** | **Scale-down uses the same gate and the same workflow** as scale-up. |
| **V10** | The 48-hour cooldown **gates proposals only, never the operator**. |
| **V11** | The ladder is an **explicit allowlist** with `Standard_B1ms` as the floor. |
| **V12** | Every resize is **verified afterward** by polling `https://game.mezin.eu/up`. |

### V1 + V2 — approval and authorisation are the same gate

The ordinary shape of a human-in-the-loop system is that the machine *can* act and is asked
politely not to: the approval is a check the code performs, so a bug in the code removes the
approval. That is not what this does.

`.github/workflows/deploy.yml` already establishes the pattern this borrows. Its Azure identity is
a user-assigned managed identity whose federated credential trusts exactly one subject —
`repo:mezinster/encounter-engine:environment:production` — and which holds Network Contributor on
one NSG and nothing else. **The subject is environment-scoped**, and GitHub does not mint an OIDC
token for a protected environment until a required reviewer approves.

So Track 1 adds two identities of its own rather than widening that one:

| Identity | Federated subject | Azure role | Scope |
|---|---|---|---|
| `vmscale-reader` | `repo:mezinster/encounter-engine:ref:refs/heads/master` | Monitoring Reader, Reader | the `web` VM |
| `vmscale-operator` | `repo:mezinster/encounter-engine:environment:vm-resize` | Virtual Machine Contributor | the `web` VM |

The poller runs unattended every fifteen minutes and can only read. The operator identity has no
usable token in existence until a human approves. A bug in `policy.rb`, a mistuned threshold, or
malicious code committed to the poller cannot resize anything — not because the code declines, but
because Azure will not accept a credential that GitHub has not been asked to issue.

**This is a configuration guarantee, not a law of physics**, and §8 lists the invariants that hold
it up along with the commands to re-verify them.

### V3 + V4 — a pure, stateless function

`ops/vmscale/policy.rb` reads a JSON document on stdin and writes a verdict on stdout. It makes no
`az` calls, opens no sockets, and reads no wall clock beyond what its input carries. The workflow
gathers every fact; the script only decides.

Two things follow. First, it is testable by construction — a fixture in, a verdict out, no stubbing
of a cloud SDK. Second, it is the seam described in §9: when the executor eventually becomes
something other than a workflow step, this file does not change.

Statelessness came from asking where the data already lives. Azure Monitor retains metrics for
93 days. The Azure Activity Log records every `Microsoft.Compute/virtualMachines/write`, which is
how the engine learns when the last resize happened without storing it. The GitHub Issue holds the
human-readable log. There was no reason to invent a state store, and not inventing one removes the
entire class of bug where the stored state says `B2s` and the VM says `B1ms`.

### V5 — credits, not CPU percentage

This is the decision that makes the system work rather than cry wolf, and §1 is the evidence.

On a burstable SKU, `Percentage CPU` at 100% is not a problem — it is the product working. The VM
banks credits while idle and spends them to burst, and this one has spent three of 288 in a week.
What actually hurts is running the bank to zero, at which point the hypervisor throttles you to the
baseline — 20% of a vCPU for a `B1ms` — and the site becomes unusable while `Percentage CPU`
reports a serene 20%.

So credit depletion is the *disease* and CPU percentage is a *symptom*, and the symptom is present
constantly without the disease. Triggers:

| Signal | Threshold | Window |
|---|---|---|
| `CPU Credits Remaining` | minimum < **30%** of the trailing 7-day maximum | 3 h |
| `Available Memory Bytes` | minimum < **200 MB** | 3 h |
| `Percentage CPU` | **≥12 of 36** five-minute points above 80% | 3 h |

Any one fires. The third is corroborating rather than decisive — it earns its place because a
sustained-CPU pattern with credits still healthy is the signature of a *new* steady load rather
than a spike, which is exactly the growth this whole exercise is watching for.

Scale-down requires **14 consecutive days** with none of the three breached and a current size
above the floor. The asymmetry is deliberate: scaling up spends money against a hard ceiling
(V7), while scaling down only risks performance, which is recoverable — but a resize costs a
reboot either way, so a hair-trigger down-proposal would trade real downtime for pennies.

Evaluating fourteen days at five-minute granularity would be 4,032 points per metric on every run,
so the workflow supplies a second, coarser series: the same three metrics at **hourly** granularity
over fourteen days — 336 points each, which is cheap. The engine groups them by date itself.

A day is **quiet** when all three hold across its hours: no hour averaged above 80% CPU, the
minimum available memory stayed above the floor, and the minimum credit balance stayed above 30% of
the seven-day maximum.

Note what the CPU criterion is *not*. An earlier draft tested each day's CPU **maximum** against the
80% line, which would have been wrong in a way the measured data makes obvious: this VM hits 90–99%
on most days, from deploys and translation runs, while spending three credits a week. Every day
would have scored as busy and scale-down could never fire. A daily maximum cannot tell a
five-minute spike from a sustained load. An hour whose *average* exceeds 80% can only be sustained,
which is why the rollup counts busy hours rather than peaks.

**Both directions move one rung at a time.** A breach on `B1ms` proposes `B2s`, never `B2ms`, even
if the evidence is dramatic — a bigger jump is a decision to make deliberately, with the smaller
one already tried. Likewise a quiet `B2ms` proposes `B2s` and waits another fourteen days before
proposing `B1ms`. Stepping straight to the floor would discard the only evidence available about
whether the intermediate rung was sufficient.

### V6 — why memory gets its own threshold rather than a share of one

200 MB against a measured worst case of 472 MB is a narrow margin on purpose. There is no graceful
degradation on this axis: memory pressure on this host does not slow the site down, it invokes the
OOM killer, and what it kills is whichever process is largest — Postgres or Puma. The recovery from
that is not a resize, it is a restore. A trigger that fires while there is still room to act is the
only useful kind.

### V7 — the budget ceiling is a verdict, not a clamp

The subscription is **Visual Studio Professional**: credit-based, roughly $50 a month, and a credit
subscription that reaches its spending limit **disables** — services stop. The platform would go
dark abruptly rather than degrade. Measured July 2026 spend was $42.54, of which two storage
accounts have since been deleted and one Backup vault stood down on 2026-08-09; the steady-state
run rate going forward is about **$25/month**.

Against that, the ladder prices out as:

| Size | vCPU / RAM | $/month | Monthly total | Inside the credit? |
|---|---|---|---|---|
| `Standard_B1ms` | 1 / 2 GiB | 17.52 | ~$25 | yes |
| `Standard_B2s` | 2 / 4 GiB | 35.04 | ~$42 | yes |
| `Standard_B2ms` | 2 / 8 GiB | 70.08 | ~$78 | **no** |

So the engine takes a `budget_ceiling_usd` input (default **45**, leaving headroom under the
credit) and will not propose a rung that breaches it. Crucially, when the top affordable rung is
already in use it returns **`at_budget_ceiling`** — a verdict distinct from `scale_up`, carrying
the same evidence but a different meaning: *you have a business decision, not an ops one*.

Collapsing that into "no proposal" would hide the most important signal the system can produce.
Collapsing it into `scale_up` would propose an action that takes the subscription offline. It is
its own outcome because it is its own situation.

### V8 + V9 + V10 — what the machine does, and what only you do

On a breach the poller comments on the long-lived decision Issue, and the same run's second job
sits pending on the `vm-resize` environment, which pushes a notification with an Approve button.
Nothing executes. If it is never approved it expires after 30 days and fails, which is the correct
outcome. (§4 explains why this is one workflow with two jobs rather than a poller dispatching a
second workflow — the obvious construction is blocked by GitHub's anti-recursion rule.)

Scale-down goes through the same workflow and the same gate. A separate ungated down-only path was
considered and rejected: it would require a third identity holding standing Virtual Machine
Contributor with no approval in front of it, which is precisely the capability this design exists
not to have. `az vm resize -g MEZINEU -n web --size Standard_B1ms` from a laptop remains the
no-ceremony escape hatch, and nothing here can prevent or intercept it.

**The 48-hour cooldown suppresses proposals only.** It is not a lock. A manual `workflow_dispatch`
during the cooldown runs normally, and so does the Portal, and so does the CLI. This is stated here
because "cooldown" is exactly the sort of word that gets misread as a safety interlock a year
later, during an incident, by someone who did not write it.

### V11 + V12 — the executor's own checks

The resize job re-derives its safety rather than trusting the proposal, because an approval may be
minutes or days old:

1. **Re-verify the target against `az vm list-vm-resize-options` at execution time.** That list is a
   property of the physical cluster the VM currently sits on. It is generous today (the whole B
   ladder in place), but a VM that is ever deallocated and rescheduled can land somewhere with a
   shorter list, at which point the proposed target would need a deallocate/start cycle instead of a
   reboot — a materially different operation that must not happen by surprise.
2. **Allowlist the target** against `{B1ms, B2s, B2ms}` with `B1ms` as the floor. A typo cannot
   resize to `B20ms`. The floor stays at `B1ms` deliberately: `B1s` halves the host to 1 GiB, which
   will not hold Rails, Postgres, kamal-proxy, danted and the APRS forwarders together.

   The allowlist and the budget ceiling are different limits and both apply. The allowlist bounds
   what the *executor* will ever apply; the ceiling (V7) bounds what the *engine* will propose.
   `B2ms` is on the allowlist and above the ceiling, which is not a contradiction: it is the rung a
   human can reach by manual dispatch after deciding to raise the ceiling or leave the credit,
   while the engine still refuses to propose it unprompted.
3. **Health-gate the result.** Poll `https://game.mezin.eu/up` until 200 or fail the job loudly. A
   resize that returns with kamal-proxy unhappy must be a red workflow, not a green one — the whole
   point of routing a manual operation through CI is to get the verification that a hand-typed
   `az vm resize` does not give you.
4. **Write the outcome back** to the decision Issue, so the log records what happened and not only
   what was proposed.

---

## 3. The policy engine contract

Input (stdin, JSON):

```
{
  "current_size":       "Standard_B1ms",
  "resize_options":     ["Standard_B1ms", "Standard_B2s", ...],
  "budget_ceiling_usd": 45,
  "baseline_usd":       7.5,            // non-compute spend: IP, disks, DNS
  "ladder":             [{"size": "...", "usd": 17.52, "floor": true}, ...],
  "last_resize_utc":    "2026-08-09T22:47:43Z" | null,
  "now_utc":            "2026-08-20T19:00:00Z",
  "metrics": {
    "cpu_percent":            [{"t": "...", "avg": 5.1, "max": 71.0}, ...],
    "available_memory_bytes": [{"t": "...", "min": 494927872}, ...],
    "cpu_credits_remaining":  [{"t": "...", "min": 285.1}, ...],
    "credits_max_7d":         288.0,
    "hourly_14d": {                       // same three series, PT1H, 14 days
      "cpu_percent":            [{"t": "...", "avg": 5.1}, ...],
      "available_memory_bytes": [{"t": "...", "min": 494927872}, ...],
      "cpu_credits_remaining":  [{"t": "...", "min": 285.1}, ...]
    }
  }
}
```

Output (stdout, JSON):

```
{
  "verdict":  "hold" | "scale_up" | "scale_down" | "at_budget_ceiling",
  "current":  "Standard_B1ms",
  "target":   "Standard_B2s" | null,
  "reasons":  ["credits_remaining min 71.2 < 86.4 (30% of 288.0)"],
  "evidence": { ... the computed aggregates, for the issue comment ... }
}
```

Exit status is 0 for any verdict; a non-zero exit means the engine itself failed and the workflow
must not proceed. `reasons` is always populated, including for `hold` — a log that only records
exceptions cannot answer "was it quiet, or was the poller broken?"

---

## 4. Files

| Path | Purpose |
|---|---|
| `ops/vmscale/policy.rb` | The pure decision function. Ruby stdlib only — no Bundler, no Rails. |
| `ops/vmscale/ladder.json` | Sizes, prices, floor flag. The one place a price is written down. |
| `ops/vmscale/gather.sh` | Every `az` call, reshaped by `jq` into one JSON document on stdout. |
| `.github/workflows/vm-scale.yml` | Two jobs: `observe` (reader identity) then `apply` (gated). |
| `spec/ops/vmscale_policy_spec.rb` | Unit tests. Requires `spec_helper` only — does not boot Rails. |
| `spec/fixtures/vmscale/*.json` | Metric fixtures, including today's real measurements. |

`policy.rb` deliberately does not live under `app/` or `lib/`. It is not part of the Rails
application, must not be autoloaded, and must remain runnable as `ruby ops/vmscale/policy.rb` on a
bare runner with no bundle installed.

**Why one workflow with two jobs, rather than a poller that dispatches a second workflow.**
The obvious construction — the poller calls `gh workflow run vm-scale-apply.yml` — cannot work:
GitHub does not create a workflow run from a `workflow_dispatch` triggered with `GITHUB_TOKEN`, a
deliberate anti-recursion rule. The alternatives are a PAT, which this repository does not use and
has been burned by before, or a GitHub App. Neither is worth it, because putting `apply` in the
same run as `observe` gets the same behaviour for free: a job carrying `environment: vm-resize`
pauses that run pending approval, and its OIDC subject is the environment, exactly as V1 requires.

That construction also fixes a problem the two-workflow version would have had. A cron running
every fifteen minutes against a persistent breach would queue a fresh approval request every
fifteen minutes. The `observe` job therefore checks for an already-waiting run of this workflow and
declines to produce a second one, so at most one approval is ever pending.

`gather.sh` exists because reshaping three Azure Monitor responses is real work that would bloat
the workflow YAML, and because it draws the line the design depends on: **the shell script gathers
and the Ruby decides.** No threshold, comparison, or verdict appears in `gather.sh` — it is the
untested half by necessity, so it must hold nothing worth testing.

One detail in `gather.sh` is load-bearing rather than stylistic: a metric point for an interval
Azure had no data for arrives with the aggregation key **absent**, not zero. Those points are
dropped, never defaulted. A missing `minimum` on `Available Memory Bytes` coerced to `0` would
manufacture the most severe breach the engine can see, out of nothing.

---

## 5. Testing

`spec/ops/vmscale_policy_spec.rb` requires `spec_helper`, not `rails_helper`, so it costs nothing in
boot time and runs inside an ordinary `bundle exec rspec` with no new gate to remember.

Fixtures:

| Fixture | Must yield |
|---|---|
| `quiet-2026-08-20.json` — today's real seven-day metrics | `hold` |
| `credits-draining.json` — credits at 22% of max | `scale_up` → `Standard_B2s` |
| `memory-floor.json` — 180 MB minimum available | `scale_up` → `Standard_B2s` |
| `sustained-cpu.json` — 20 of 36 points above 80%, credits healthy | `scale_up` |
| `already-b2s-breaching.json` — on `B2s`, breaching, `B2ms` unaffordable | `at_budget_ceiling` |
| `quiet-14-days-on-b2s.json` | `scale_down` → `Standard_B1ms` |
| `within-cooldown.json` — breaching, last resize 6 h ago | `hold`, with the cooldown named in `reasons` |
| `target-not-offered.json` — `B2s` absent from `resize_options` | `hold`, with the reason named |

The first fixture is the important one. Real measured data that must return `hold` is the guard
against a threshold that looks reasonable in the abstract and fires constantly in production —
which is the specific way this class of tool usually fails.

Each threshold additionally gets a **mutation check**: nudge the constant, and the verdict must
flip. A test that passes with the threshold set to any value is not testing the threshold. This
follows the pattern already used for `countdown_plural_function`, where a Ruby mirror of the rule
would have agreed with itself while the shipped code stayed broken.

---

## 6. Failure modes accepted

- **GitHub cron lag.** Scheduled workflows are best-effort and can run 10–20 minutes late under
  platform load. A 15-minute cadence therefore means "you hear within roughly half an hour", not
  fifteen minutes. Acceptable for a propose-only system; it would not be acceptable for an
  autonomous one, and is part of why this one is not autonomous.
- **Scheduled workflows are disabled after 60 days of repository inactivity.** This repo is active
  daily, so it is a theoretical concern — but if the project ever goes quiet, the watcher goes quiet
  with it, silently. Noted rather than solved.
- **A pending approval expires after 30 days** and the run fails. Correct behaviour, listed so the
  failure is recognised when it appears.
- **Metrics gaps.** If Azure Monitor returns fewer points than the window expects, the engine
  returns `hold` and says so. It never infers a breach from missing data.

---

## 7. Non-goals

- No autonomous execution, in either direction.
- No game-schedule awareness. The obvious v2 is a "N runs currently active" readout in the proposal
  comment, so the approver can see what a reboot would interrupt. It needs either an app endpoint or
  an SSH path through the NSG, and the operator already knows their own calendar.
- No multi-VM generality. The config is shaped as a list, but it has one entry.
- No alerting beyond the GitHub Issue and its notifications.
- No changes to `config/deploy.yml`, the `production` environment, or the NSG identity.

---

## 8. Invariants, and how to re-verify them

The guarantee in V1 rests on four facts. Any of them can be undone by a careless afternoon, so they
are written down with their checks:

1. The `vm-resize` GitHub Environment has a required reviewer.
   `gh api repos/mezinster/encounter-engine/environments/vm-resize`
2. `vmscale-operator` has **exactly one** federated credential, subject
   `repo:mezinster/encounter-engine:environment:vm-resize`.
   `az identity federated-credential list --identity-name vmscale-operator -g MEZINEU`
3. `vmscale-reader` holds **no** write role anywhere.
   `az role assignment list --assignee <reader-principal-id> --all -o table`
4. Neither identity holds a role at subscription or resource-group scope — both are scoped to the
   `web` VM resource id alone.

---

## 9. What Tracks 2 and 3 would change

Recorded so the seam in §3 is real rather than aspirational, and so the deferred decision is
retrievable. Neither is built here.

**Track 2 (~+$19/month)** unbundles state: uploads to Blob via ActiveStorage; wal-g's
system-assigned managed identity replaced by a user-assigned one that survives VM replacement;
Postgres to Azure Database for PostgreSQL Flexible Server (Burstable B1ms, $14.53, plus 32 GB at
$4.38).

**Track 3** replaces resizing with blue/green — provision a new VM at the target size, deploy,
health-check, move the static IP, destroy the old — turning 90 seconds of downtime into seconds.
**It is blocked on Track 2, specifically on Postgres.** Uploads are not a real blocker (rsync during
cutover) and the identity is not either (a user-assigned MI is an afternoon). But with the database
still on the box, blue/green means stopping Postgres, copying a volume and starting it elsewhere —
*longer* downtime than the reboot it was meant to avoid. The only alternative is streaming
replication and promote, which is Track 2 done by hand.

**What would change in Track 3:** `policy.rb` and its contract, not at all. The executor workflow is
replaced by an orchestrator with rollback — plausibly a Durable Function, since the step sequence is
no longer a single idempotent CLI call. That substitution is the entire reason the engine is a pure
function today.

**When to revisit:** when the decision log shows `B2s` under sustained pressure, or when the
dev/test licensing status of the Visual Studio credit forces a billing move regardless of capacity.
Re-measure the costs at that point; two line items in the July figures above had already vanished by
the time they were written down.
