# Load testing the production VM — design

**Date:** 2026-08-21
**Status:** design approved in chat; implementation plan not yet written
**Related:** `docs/superpowers/specs/2026-08-05-kamal-deployment-design.md`, `docs/runbooks/restore.md`

## 1. The question this answers

**How many concurrent teams can the production VM carry before play becomes
unacceptably slow?**

That number sizes the VM for the next real game, and it is the input the
approved Track 1 resize was costed against. Everything below exists to produce
it honestly.

It is a *capacity ceiling* exercise, not a profiling exercise and not a
regression gate. It runs against production, off-hours, on a scratch game.

### 1.1 Non-goals

* Not a CI check. This never runs on a pull request.
* Not a saturation study. We deliberately stop before the host falls over —
  see §4.
* Not a per-endpoint profile. If the ceiling turns out to be caused by one slow
  action, that is a *follow-up* investigation with its own design.
* No `.feature` file is added. The acceptance suite is frozen and this is a
  tool, not application behaviour. Stated explicitly so nobody adds one later
  "for completeness".

## 2. Constraints that shape the whole design

**The target is a single burstable VM shared with other services.** The host
runs danted on 1080, squid-family proxies on 3128-3130 and 8080-8081, and two
inReach APRS forwarders (`ansible/playbook.yml`). We are a tenant, not the
owner. Anything that saturates the CPU degrades all of them, and none of them
belong to this app.

**Burstable means the ceiling is two numbers, not one.** The VM banks CPU
credits while idle and spends them under load; when the bank empties it is
throttled to its baseline share of one vCPU. A ramp run while credits are full
measures a machine that players only get for the first minutes of a game. The
number that predicts hour two is the sustained one, measured after the credits
are gone. The design produces both, and treats reporting only the first as a
defect.

**This app never polls.** The only `setInterval` in the views is the
client-side countdown (`app/views/shared/_countdown.html.erb:110`), which never
contacts the server, and the play screen has no auto-refresh. An idle team
therefore costs exactly zero requests. Load is entirely human-paced and spiky.
A script without think time would generate roughly two orders of magnitude more
traffic than the team count implies and would "discover" a ceiling no real game
can reach.

**Generator capacity is not a constraint; measurement fidelity is.** At roughly
two requests per 70-second cycle, 120 teams is about 3.4 requests/second. Any
machine can produce that. What matters is that network noise does not
contaminate a p95 threshold set at 2000ms.

**The expensive event is the start-of-game stampede, not steady play.**
`SessionsController#create` calls `user.authenticate`, i.e. bcrypt — tens of
milliseconds of pure CPU per login that no cache or index can reduce. Two
hundred teams logging in inside a minute is the most CPU-dense minute this app
ever experiences.

## 3. Approach

Three approaches were considered:

* **A. SLO-bounded stepped ramp, then a sustained hold.** *Chosen.* Phase 1
  steps the arrival rate up in plateaus with a k6 threshold carrying
  `abortOnFail`, so the run is killed at the first plateau that breaches the SLO
  and the host never actually saturates. Phase 2 re-runs at ~70% of that level
  and holds it past credit exhaustion.
* **B. True ramp-to-failure.** Rejected. Would show *how* the box fails, but
  takes danted, the squid proxies and the APRS forwarders down with it, and on
  one vCPU the failure mode is most likely undramatic Puma queueing. High
  collateral cost for modest extra insight.
* **C. Aggressive ramp on a throwaway clone, confirming hold on production.**
  The best engineering answer and rejected only on cost: a clone has neither
  production's credit history nor its neighbours, so its ceiling is a hypothesis
  rather than a result, and it costs an extra VM plus a Kamal deploy.

**Failure is defined as an SLO breach, not a crash:** `p(95) > 2000ms` or an
error rate above 2%. The last plateau that stayed clean is the reported burst
ceiling.

## 4. Components

### 4.1 The seed harness

The play path needs substantial state before a single request is meaningful.

* **`Game`** — `access_mode: "scheduled"`, `points_enabled: true`. Points on
  deliberately: `point_transactions` writes are part of the real cost of an
  accepted answer, and testing with points off measures a cheaper app than we
  run.
* **`GameRun`** — `is_testing: true`, with a `test_token`, and `starts_at` in
  the **past**: `#show_current_level` refuses with `game.not_started` unless
  `viewing_a_started_run?` (line 979). A run seeded with a future start date is
  seeded unplayable.
* **A separate author account**, which never plays. `cannot_play_own_game`
  (line 1000) rejects the game's own author, so if the author were reused as a
  team member that VU would fail every request.
* **N `Team`s**, each with a captain plus two members. `users.team_id` is a
  plain column, so a team is simply N users pointing at it.
* **`TestAdmission`** per team, scoped to the run — **not** `GameEntry`. These
  are two distinct admission paths in `GamePassingsController`: an ordinary run
  authorises with `GameEntry.of(@team, @game.current_run)&.status == "accepted"`
  (line 904), while a test run short-circuits that with `return if
  test_admission` (line 918). Because §4.1.2 uses `is_testing: true`, the
  cohort needs `test_admissions` rows. `user_id` stays NULL so the admission is
  team-wide, which the unique index permits.
* **`GamePassing`** per team, pre-advanced to **varied** level depths.
* **~30 `Level`s**, each with a known code (via `correct_answer`), with mixed
  `wrong_answer_penalty` and `any_code_passes`.

Varied depth is not cosmetic. `GamePassing#answered_questions` goes through
`AnsweredQuestionsCoder`, which re-serialises the whole blob on every accepted
answer, so the write cost grows with progress. Seeding every team at level 1
confines the test to the cheap end of a curve real games spend most of their
time on the expensive end of.

#### 4.1.1 Seeding users into production is a security event

Hundreds of accounts with known passwords are being created in the live
database. Mitigations are part of the design, not operational discipline:

* a fresh random 32-character password generated per run — never a constant,
  never committed;
* addresses under `@loadtest.invalid`, a reserved TLD, so no mail can reach a
  real recipient even if something decides to send some;
* a distinctive nickname prefix carrying the cohort id, so the cohort is
  greppable;
* teardown is **mandatory**: the seed task prints the exact teardown command as
  its final line;
* `seed` refuses to run while a previous cohort is still present, so a forgotten
  teardown blocks the next run instead of silently doubling up.

#### 4.1.2 The scratch game will be publicly visible

`Game::VISIBILITIES` is `%w[draft listed]` — there is no unlisted state and a
draft is not playable, so **there is no way to have a playable game nobody can
see**. This is accepted rather than solved.

The mitigation that carries the weight is `is_testing: true` on the run:
admission goes through `test_admissions` and a token, so a passing real user can
see that a game exists but cannot join it. The game is named unmistakably
(`НЕ ИГРА — нагрузочный тест, <date>`) so nobody wastes time on it.

**To confirm during implementation, not assume:** that the test-run token gate
actually refuses an uninvited authenticated user. If it does not, the run must
move to `access_mode: "pass_required"` instead.

### 4.2 Task interface

`lib/tasks/load_test.rake` stays a thin shell; the logic lives in a plain
`LoadTest::Seeder` under `lib/load_test/` so it is unit-testable without
invoking rake.

```
bin/rails load_test:seed[teams,levels]
bin/rails load_test:teardown[cohort_id]
bin/rails load_test:status
```

`seed` writes a **manifest JSON** — the contract between Ruby and k6:

```json
{ "cohort_id": "lt-2026-08-21-a", "game_id": 42, "run_id": 87,
  "base_url": "https://game.mezin.eu",
  "teams": [ { "email": "...", "password": "...", "team_id": 3 } ],
  "codes": { "12": ["К1", "К2"], "13": ["К7"] } }
```

k6 reads it through `SharedArray`, so 200 VUs share one parsed copy rather than
holding 200. The manifest is written outside the repo, is gitignored, and is
deleted by teardown.

**Production guard:** under `RAILS_ENV=production` both tasks refuse unless
`LOAD_TEST_CONFIRM` matches the cohort id — not because it would be run by
accident, but because its whole job is creating and deleting hundreds of
production rows, and it will eventually be run by someone following a runbook
late at night.

### 4.3 The k6 script

One entry point, two phases selected by `--env PHASE=`, because phase 2's hold
level is an input derived from phase 1's result and they cannot be a single run.

```
load_test/
  main.js          # scenario selection by PHASE
  lib/auth.js      # login + CSRF scrape, once per VU
  lib/play.js      # level GET, answer POST, checks
  lib/manifest.js  # SharedArray over the seeder's JSON
```

**Phase `ramp`** — `ramping-arrival-rate`, plateaus at 10 → 20 → 40 → 80 → 120
teams, four minutes each, `abortOnFail: true` on `p(95)<2000` and
`http_req_failed rate<0.02`, with `delayAbortEval: '30s'` so one cold-start
outlier cannot kill a run before there is a meaningful sample.

**Phase `hold`** — `constant-arrival-rate` at `--env RATE=<70% of ceiling>` for
40 minutes, no abort, thresholds recorded rather than enforced. This is the run
that outlives the credit bank.

The per-VU flow, from the real routes:

1. `GET /login`, scrape `authenticity_token`
2. `POST /login` with flat `email` / `password` params
   (`app/views/sessions/new.html.erb` uses `email_field_tag`, not nested params)
3. loop: `GET /play/:game_id`, think 20–90s, `POST /play/:game_id` with
   `answer` plus the token (`config/routes.rb:372-373`,
   `app/views/game_passings/show_current_level.html.erb:227`)

Answer mix is an explicit parameter, defaulting to 85% wrong / 15% correct. A
correct code advances the level, rewrites the passing and posts to the points
ledger; a wrong one writes a log row. Those costs differ enough that the ratio
must not fall out of the data by accident.

Two rules the script may not break:

* **Every check asserts on body content, never on status alone.** k6 follows
  redirects by default, so a failed login yields a cheerful 200 for the rest of
  the run and a status-only script reports a flawless test against an app it
  never authenticated to.
* **The CSRF token is scraped once per VU and cached.** Rails masks the token
  per render but accepts any valid unmasking for the session, so re-fetching
  before every POST would add a phantom GET to every write and distort the
  read/write ratio.

### 4.4 Where the generator runs

**Provisioning is `az` CLI in a shell script, not Terraform.** This repository
has no Terraform, no Bicep and no ARM templates; its only infrastructure code is
`ansible/` for configuring the existing host. Introducing Terraform would mean
bootstrapping remote state, a lock, provider auth and a new competency — for one
VM that lives about two hours. Terraform earns its keep on long-lived resources
with drift to manage; this has neither.

The load generator is created in **its own resource group**, and teardown is
`az group delete`. This is the point of the choice: `az vm delete` leaves the
NIC, NSG, public IP and OS disk behind, quietly billing. Deleting the group
removes everything or fails loudly.

Configuration is **cloud-init**, not an Ansible play. Ansible would match the
repo's convention, but `ansible/inventory.ini` is pinned to the `mezin` ssh
alias because WSL2 reaches the host through a `ProxyCommand`; an ephemeral host
would mean editing the inventory for every run. cloud-init is one file and no
inventory at all.

Three stages:

1. **Script development — the WSL laptop against the local dev app.** Free,
   fast, and required by §6 regardless. Never touches production.
2. **The real runs — a throwaway `Standard_B1s` in westeurope**, the same region
   as the target, deleted the same evening. The reason is fidelity, not
   capacity: a home connection injects RTT and jitter into every
   `http_req_duration` sample, and we are judging a p95 breach at 2000ms.
   Traffic still leaves via the public FQDN, so kamal-proxy and TLS termination
   are exercised normally.
3. **Repeatability later — GitHub Actions.** The app answers publicly on 443, so
   a runner needs no NSG hole; the OIDC dance in `.github/workflows/deploy.yml`
   exists only for SSH and Kamal. Worth wiring once the script is stable. Not
   for the first runs: a ramp cannot be watched and aborted interactively from a
   runner, and the runner's region is not controllable.

k6 Cloud was rejected — a thin free allowance and a third-party dependency for
something a one-cent VM does better.

## 5. Safety

### 5.1 Layered aborts

* **Automatic (k6).** The thresholds in §4.3. Slowest of the three to react.
* **Human.** Someone watching Azure Monitor with a finger on Ctrl-C, for the
  things k6 cannot see: CPU credits draining faster than the plateau schedule
  predicts, distress in danted / the squid proxies / the APRS forwarders, or any
  sign of a real user on the box.
* **Recovery.** `kamal app boot` if memory ballooned. On roughly 1.1 GB spare, a
  Puma worker that grows under load does not necessarily shrink back.

### 5.2 Pre-flight, in order

1. Query `game_runs` for any `starts_at` inside the window; abort if a real game
   is scheduled anywhere near it.
2. Confirm the wal-g backup is current. `docs/runbooks/restore.md` is the
   recovery path if this goes badly wrong.
3. Record a 10-minute idle baseline — p95 under no load, and the starting credit
   balance. Without it a slow app cannot be distinguished from a slow path.
4. Seed, capture the manifest, and log in by hand once before launching 120 VUs.

### 5.3 Teardown deletes explicitly and then proves it

`GameRun` declares `has_many :passings` with **no `dependent:` option**,
deliberately — its comment records that a passing is the record of a race
somebody ran. Destroying the game therefore does **not** remove
`game_passings`, and load-test rows would persist in production indefinitely.

Teardown deletes in dependency order — `point_transactions`, `game_passings`,
`test_admissions`, `game_entries`, `access_passes`, users, teams, then the game
with its levels —
and then **asserts every touched table is back to its pre-seed row count**,
failing loudly if not. `load_test:status` exists so the clean state can be
confirmed days later.

## 6. Verification

**The seeder — ordinary RSpec**, `spec/lib/load_test/seeder_spec.rb`:

* seeds the requested shape: team count, level count, varied passing depths;
* **teardown restores exact pre-seed row counts** across every touched table.
  This is the load-bearing example — it is what catches the `dependent:`-less
  `passings` trap in §5.3;
* the production guard refuses without a matching `LOAD_TEST_CONFIRM`;
* seeding refuses while a previous cohort is present.

Specs use the existing helpers in `spec/spec_helpers/fixtures_helper.rb`
(`create_user`, `create_game`, `create_level`), per this repo's no-FactoryBot
convention. The seeder itself does not use them — that helper is test-only.

**The k6 script — proven locally, then mutation-tested.** RSpec cannot reach it.
Seed a five-team cohort against the dev app, run `PHASE=ramp` with small
numbers, confirm the checks are green — and then deliberately break it and
confirm it goes red. Two mutations at minimum:

* corrupt the password in the manifest: must fail on the body check, rather than
  returning 200 forever;
* corrupt the `authenticity_token`: must surface as 422.

Without those, a green run proves only that the script ran. This is a recurring
failure mode in this repository, not a hypothetical: `CLAUDE.md` records the
countdown examples reporting *pending* in CI for a fortnight while reading as
passes, and a HEIC support check that reported success on a machine that could
not decode a byte.

**Gates before merge:** full `bundle exec rspec`; the inherited 228/2325
Cucumber contract still green; and `bin/rails zeitwerk:check`, which is not a
formality here because `lib/load_test/` gets autoloaded.

## 7. Deliverables

| Path | What |
|---|---|
| `lib/load_test/seeder.rb` | cohort creation, teardown, status |
| `lib/tasks/load_test.rake` | thin shell over the above |
| `spec/lib/load_test/seeder_spec.rb` | seeder specs, incl. row-count restoration |
| `load_test/main.js` | k6 entry point, phase selection |
| `load_test/lib/{auth,play,manifest}.js` | k6 modules |
| `load_test/provision.sh` | `az group create` + `az vm create` + cloud-init |
| `load_test/cloud-init.yml` | installs k6 on the generator |
| `docs/runbooks/load-test.md` | the run-night protocol from §5 |

## 8. To confirm during implementation

1. That the `is_testing` run's token gate actually refuses an uninvited
   authenticated user (§4.1.2). If not, switch to `access_mode: "pass_required"`.
   Related: line 885 notes a team gets a `GameEntry` "by construction" in the
   test-game features, so confirm whether a test run needs *both* rows in
   practice or `test_admissions` alone is sufficient.
2. Whether `point_transactions` rows are removed by any existing cascade, or
   must be deleted explicitly as §5.3 assumes.
3. The real per-request CPU cost, which decides whether the §4.3 plateau ladder
   (10→120) brackets the ceiling or needs re-scaling after the first run.
