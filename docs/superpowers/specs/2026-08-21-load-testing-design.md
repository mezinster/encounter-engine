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
* **Levels — cloned from a real game by default** (§4.2.1), synthetic only as a
  fallback. Cloning is both the cheapest way to supply prerequisites and the
  more honest test: real level text and real code counts, not filler.

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
* **nothing mails.** Production SMTP is Gmail, which suspends senders that trip
  its spam heuristics — `RequestThrottling`'s class comment records that hazard
  already. All six mailer send sites are in controllers; no model or `lib` code
  mails at all, so the seeder's model-layer writes cannot produce a message. A
  spec pins this, because an `after_create` mailer on `User` would otherwise
  start mailing hundreds of production addresses silently. The corollary binds
  the k6 scenario too: it drives `/login` and `/play/:game_id` only, and must
  never be extended to registration;
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

### 4.2.1 Cloning a source game

`LoadTest::GameCloner` deep-copies an existing game into the scratch game. **No
clone or duplicate logic exists anywhere in this codebase today** — this is new.

Copied: the `Game` row (renamed, re-authored to the throwaway author), its
`levels` in `position` order, and each level's `questions`, `answers` and
`hints`.

Deliberately not copied: `logs`, `game_entries`, `game_passings`, `access_passes`,
`access_codes`, `point_transactions`, `translation_runs` — history and
permission belonging to the real game, none of it meaningful in a clone — and
`game_files`.

**The `game_files` omission is a known, accepted inaccuracy.** A cloned level
whose text references an attached file will render that reference broken, so a
cloned level page is somewhat lighter than the original. It is called out here
rather than fixed because copying the blobs would multiply storage on a host
with ~1.1 GB spare, to make page weight marginally more accurate on a test whose
bottleneck is CPU.

The cloner is a plain class under `lib/load_test/`, not a `Game` instance
method: it is a load-testing concern and must not become a general-purpose
"duplicate game" feature by accident.

### 4.2.2 The superadmin console screen

`GET /admin/load_test` plus `POST` actions for seed and teardown, following the
established console shape exactly:

* `Admin::LoadTestsController` with `include SecurityFilters`, `include
  AdminAudit`, `before_action :require_authentication!`, `before_action
  :require_superadmin!` — the same four lines every other admin controller
  carries.
* The form supplies the prerequisites: source game (a select of existing games),
  team count, answer mix, and a **typed confirmation of the cohort id** before
  either destructive button acts. A button that creates hundreds of production
  users must not be one misclick.
* The screen shows current cohort status and offers the manifest as a download,
  so the operator never needs SSH to obtain it.

**Audit is mandatory, and is a task in its own right.** `AdminAudit` records by
an explicit `record_admin_action` call at each site, never an `around_action` —
the concern's own comment explains that a filter deciding auditability by
inspecting the request is precisely the construct that silently stops covering
new actions. Both seed and teardown call it with details (cohort id, source
game, team count), and `spec/requests/admin_audit_spec.rb` **enumerates the
audited actions**, so it must be updated deliberately.

**i18n cost, priced deliberately.** Admin screens in this repo are fully
translated (`app/views/admin/users/show.html.erb` runs every label through
`t("admin.users.show.*")`). A new screen therefore needs an `admin.load_test.*`
block in **all seven** locale files; `raise_on_missing_translations` in the test
environment turns an omission into a red build rather than a cosmetic gap. This
roughly doubles the size of the work relative to the rake-only design and was
accepted as such.

**The rake tasks remain**, and remain the interface used on run night from the
generator VM. The console is an additional front door onto the same
`LoadTest::Seeder`, not a replacement — a screen that reimplemented the logic
would drift from it.

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

**The generator is closed to the internet, and this matters more than it looks:
it holds the manifest** — a live password for every seeded captain plus every
level's answer codes. An SSH port open to the world on a box holding production
credentials is a real exposure, not a hygiene point.

It is created with `--nsg-rule NONE`, so no allow-SSH-from-anywhere rule is
generated and Azure's default `DenyAllInBound` governs. One rule is then added
allowing 22 from the operator's own address only — the same just-in-time pattern
`.github/workflows/deploy.yml:131-156` already uses for deploys, where a rule
scoped to `${RUNNER_IP}/32` is created and deleted within the same job.

**The public IP stays, and is for outbound only.** Azure retired default
outbound access in September 2025, so a VM with no public IP and no NAT gateway
has no internet at all — which defeats the entire purpose, since the generator's
only job is to reach `game.mezin.eu`. A Standard-SKU public IP is closed to
inbound by default and opens only where the NSG says so.

A zero-inbound variant exists — driving the VM through `az vm run-command
invoke`, which reaches the guest agent over its outbound connection and needs no
open port at all. It is rejected here because a ramp has to be *watched* and
abortable, and run-command returns its output at the end rather than streaming.

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

Teardown deletes in dependency order — `logs`, `point_transactions`,
`game_passings`, `game_entries`, `test_admissions`, `access_passes`,
`invitations`, `team_join_requests`, `game_locale_preferences`, users, teams,
then the game with its levels — and then **asserts every touched table is back
to its pre-seed row count**, failing loudly if not. `load_test:status` exists so
the clean state can be confirmed days later.

**`logs` is the entry this design got wrong first, and it is the largest table a
run writes.** `Game has_many :logs` (`app/models/game.rb:62`) carries no
`dependent:` option — the identical trap described just above for
`:game_passings`, which is declared two lines further down the same file — and
`GamePassingsController#save_log` writes a row on *every* answer POST, which is
the entire per-VU loop. A 120-team, 40-minute run would therefore have left on
the order of ten thousand orphaned rows in production while teardown reported
success. The omission was found by probing a scratch database, not by reading
the list again.

**A second class of survivor: `delete_all` runs no callbacks.** `User` declares
`invitations`, `team_join_requests` and `game_locale_preferences` as
`dependent: :destroy` (`app/models/user.rb:23-25`), and `Team` declares the
first two (`app/models/team.rb:21-22`). Deleting rows in bulk skips every one.
The play screen's content-language switcher is what writes
`game_locale_preferences`, and `user.rb:17-21` records that an orphaned
`team_join_request` 500s an unrelated captain's team room — so these are deleted
explicitly rather than left to a callback that will not run.

**Teardown validates the cohort id it is given** against the cohort actually
present, and refuses on a mismatch. Scoping deletion by e-mail domain alone means
`teardown!("yesterdays-cohort")` deletes *today's* and reports success — and the
production guard cannot catch that, because it compares the operator's typed
confirmation against the operator's typed argument, never against reality.

**A tracked table that is empty on both sides proves nothing.** The row-count
example must create a row in every table it tracks — `point_transactions` above
all, since the real run writes to that ledger on every correct answer — or the
corresponding deletion line is unverified and can be removed without turning the
suite red.

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

**The cloner — RSpec.** That a clone reproduces level count, `position` order,
codes and hints; and — the example that matters — that it copies **none** of the
excluded associations. Asserting what was *not* copied is the half that catches
a future association being added to `Game` and silently swept into every clone.

**The admin screen — request specs**, matching the console's existing coverage:
that a non-superadmin is refused, that seed and teardown each write an
`AdminAction`, and that the typed cohort-id confirmation is actually enforced
rather than merely rendered. `spec/requests/admin_audit_spec.rb` gains both new
actions.

**i18n — the existing guards do the work.** `spec/i18n_spec.rb` enforces exact
`ru`/`en` parity and will fail on a key added to one and not the other. The five
machine-produced locales need the block too, since `locales`-adjacent gaps in
admin chrome fall back silently rather than loudly.

**Gates before merge:** full `bundle exec rspec`; the inherited 228/2325
Cucumber contract still green; and `bin/rails zeitwerk:check`, which is not a
formality here because `lib/load_test/` gets autoloaded.

## 7. Deliverables

| Path | What |
|---|---|
| `lib/load_test/seeder.rb` | cohort creation, teardown, status |
| `lib/load_test/game_cloner.rb` | deep-copy of a source game (§4.2.1) |
| `app/controllers/admin/load_tests_controller.rb` | console screen (§4.2.2) |
| `app/views/admin/load_tests/show.html.erb` | the form, status and manifest link |
| `config/locales/*.yml` | `admin.load_test.*` in all seven |
| `spec/lib/load_test/game_cloner_spec.rb` | clone specs, incl. what is NOT copied |
| `spec/requests/admin/load_tests_spec.rb` | guards, audit, confirmation |
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
4. Whether a cloned level whose text references a `game_file` renders an error
   or merely a broken link (§4.2.1). An error would make the clone unusable and
   would force either copying the files or rewriting the text on clone.
