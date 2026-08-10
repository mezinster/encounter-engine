# Game runs, phase 3: opening a second run and admitting teams to it — design

**Date:** 2026-08-10. **Decided by:** repository owner (`mezinster`), in session.

## 0. Where this sits

The feature the whole programme exists for. Phases 1 and 2 are merged, deployed and verified;
neither changed anything a user could see.

| # | Sub-project | State |
|---|---|---|
| 1 | `game_runs` exists; the schedule moves off `games`; `Game` delegates | merged, deployed (PR #68) |
| 2 | Results, logs and stats become run-scoped | merged, deployed (PR #69) |
| **3 — this spec** | **A superadmin opens a second run; teams register for it; earlier runs' results stay readable** | **user-visible** |

The original problem: a finished game cannot be played again, and the author's only remedy is to
create a second game and re-enter every question. The obstacle was never the play code — a team
starting months late already gets correct hint timing, because `GamePassing`'s clock is per team.
The obstacle was that **results were ranked across every cohort by absolute timestamp**, so a later
group always placed last. Phase 2 fixed that by scoping results to a run. This phase lets a second
run exist.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | How do teams get into run 2? | **Normal registration, per run.** `GameEntry` becomes run-scoped; a team applies and is accepted exactly as it always has. |
| D2 | Which screens can show an earlier run? | **The results page only**, via `?run=<ordinal>` plus a switcher. Logs and stats stay on the current run. |
| D3 | What does opening a run take, and who may do it? | **A superadmin**, supplying start time, registration deadline and team cap in one form. |

### Why D1

The entry flow is the consent mechanism: a team applies, an author accepts. Admitting teams directly
would create a second admission path alongside it and enter a team in a game it never applied to.
Carrying run 1's teams over by default is the wrong default for the stated goal — giving *other*
teams a chance at a finished game.

### Why D2

The results page is the only screen a player cares about, and it is the one that must not lose
history when a second run opens. The four log screens carry the most intricate access rules in the
application (`ensure_full_log_access`, `find_level` via `Team#current_level_in`), and giving them a
run parameter serves a case nobody has asked for. Deferred, not forgotten.

### Why D3

Matches the original request, and mirrors `Admin::GamesController#set_author` — the console's only
other non-`index` action. Supplying the schedule inline means the run is fully configured the moment
it exists, so the game is never publicly listed half-set-up.

## 2. Two blockers this phase must clear

Both are live in production today and would surface as opaque failures.

### 2.1 The `game_entries` unique index locks out returning teams

`db/schema.rb` carries:

```
index_game_entries_on_team_id_and_game_id_live
  UNIQUE (team_id, game_id) WHERE status IN ('new', 'accepted')
```

It was added on 2026-08-08 to stop a double-clicked "apply" creating two simultaneously live entries.
Run 1's accepted entries stay `accepted` for ever, so **every team that played run 1 is permanently
barred from applying to any later run of that game** — by a database constraint, with an opaque
uniqueness error and no message a captain could act on.

The index becomes `UNIQUE (team_id, game_run_id) WHERE status IN ('new','accepted')`, added the way
its predecessor and phase 2's passings index were: **check for duplicates first and `say` rather than
raise.** Migrations run under `bin/docker-entrypoint`'s `db:prepare` before puma starts, so an index
that raises on unexpected data takes the whole app down mid-deploy.

### 2.2 A run with no team cap crashes registration

`Game#can_request?` is `requested_teams_number < max_team_number`. A run created without a cap makes
that `0 < nil`, which raises `ArgumentError` on the registration path. This is why D3 requires the
cap up front rather than creating a bare run and configuring it later.

## 3. Opening a run

`Admin::GamesController#open_run` — the console's second non-`index` action. A per-row form supplies
`starts_at`, `registration_deadline` and `max_team_number`; the action creates a `GameRun` with
`ordinal = <max for that game> + 1`.

Refusals, each returning **before anything changes**, matching the shape every other administrative
action in this codebase uses:

| Condition | Why |
|---|---|
| the current run is not finished (`author_finished_at` nil) | run 2 cannot open while run 1 is still being played |
| the game has no levels | a run of nothing is not playable |
| the three fields fail validation | same rules `Game` applies today |

Audited as `open_run` with the new ordinal in `details`, labelled in all seven locales. The audit
view falls back to the raw action name on a missing key, so the label is asserted by a spec that
checks the identifier is **absent** from the log — the same guard phases past have used.

**`GameRun` gains its own validations here.** Phase 1 (D4) deliberately left the four schedule
validations on `Game`, reading through the delegation, and recorded that a run first becomes
creatable without a game form in front of it in phase 3. That is now.

## 4. Entries become run-scoped

```
game_entries.game_run_id        already present, backfilled by phase 1, still unread
unique index                    (team_id, game_id)  ->  (team_id, game_run_id)
GameEntry.of(team, game)        ->  GameEntry.of(team, run)
entry creation                  sets game_run_id
may_start_passing?              asks the CURRENT run's entry
```

`GameEntry.of` itself has **four** call sites, three of them in views. Three further sites reach
entries through `of_game`/`of_team` and need the same treatment:

| Call site | Form |
|---|---|
| `GamePassingsController#may_start_passing?` | `GameEntry.of` — the gate that decides who may play |
| `app/views/dashboard/_coming_games.html.erb:13` | `GameEntry.of` |
| `app/views/shared/_countdown.html.erb:46` | `GameEntry.of` |
| `app/views/shared/_current_games.html.erb:16` | `GameEntry.of` |
| `GameEntriesController:22` | `of_team(...).of_game(...)` — the duplicate-application check |
| `GamesController:51-52` | `of_game(...).with_status(...)` — the author's pending/accepted lists |
| `DashboardController:12` | `of_game(...).with_status("new")` |

All resolve `game.current_run` — every one is reached by a URL or a listing that knows a game and no
run, the same rule phase 2 applied.

**Capacity needs no work.** `max_team_number` and `requested_teams_number` moved to the run in phase
1, so run 2 gets a fresh cap and `reserve_place_for_team!` counts into the right run already.

## 5. The results run switcher

`GamePassingsController#show_results` accepts an optional `run` parameter carrying the **ordinal**,
not the id: stable, human-readable, and meaningful in a URL a player might share. Absent, unknown or
malformed falls back to the current run rather than 404ing — a stale bookmark should show the current
standings, not an error.

The page gains a switcher listing each run with its start date. **With one run it renders nothing at
all**, which is what keeps today's page byte-identical and the frozen scenarios green.

Two new locale keys across seven files.

## 6. What opening a run does to the game

`Game#status` reads the current run, so opening run 2 flips the game from `:finished` back to
`:scheduled`. It reappears in the public list and in «Ближайшие игры» and leaves «Завершённые игры».
That is correct: it is open for registration again, and run 1's standings stay reachable at `?run=1`.

**A consequence recorded rather than fixed.** `started?` becomes false again, and
`ensure_game_was_not_started` gates `edit`, `update`, add-level and quiz-import — so opening a run
**re-opens content editing**. That is useful (fixing a broken level before the rerun) and it also
means an author can change the questions between runs, leaving the two runs' standings not strictly
comparable. Locking content across runs is a real design question; this phase deliberately does not
answer it, because nobody has asked for it and the alternative is telling an author their typo is
permanent.

## 7. Testing

**Opening a run** — creates `ordinal = max + 1`; refuses while the current run is unfinished; refuses
a game with no levels; refuses a non-superadmin; writes one audited `open_run` entry carrying the
ordinal; and the audit log renders a sentence rather than the raw action name.

**Admission — the two that matter most:**

- a team whose **run-1 entry is `accepted` can apply to run 2**. This is §2.1's index fix, and
  without it the database refuses with an opaque error;
- that same team **cannot play run 2 on its run-1 entry alone** — `may_start_passing?` must ask run 2.

**Capacity** — filling run 2 to its cap neither depends on nor disturbs run 1's counter.

**The switcher** — after run 2 opens, `?run=1` shows run 1's standings and no parameter shows run 2's;
an unknown or malformed ordinal falls back to the current run; and **a single-run game renders no
switcher markup at all**, which is what protects the frozen scenarios.

**The entries index guard** is exercised against a table that already contains duplicates — index
absent, duplicates present — because a guard that has only ever run against clean data is untested.
Phase 2 established this pattern.

**Cucumber must stay at exactly 232 scenarios / 2342 steps.** This is the first phase users can see,
so it is the first where a frozen scenario could legitimately notice something. If one breaks, the
design is wrong, not the scenario.

## 8. Frozen acceptance surface

No `features/**/*.feature` file is edited. The results page, the dashboard entry lists and the
countdown are all driven by frozen scenarios, and every change here is either invisible on a
one-run game (the switcher) or behind the admin console (opening a run).

## 9. Out of scope

Logs, the live channel and the author's passings list stay on the current run. No UI to rename,
reschedule or delete a run once opened, and no per-run announcements or e-mail. Content is not locked
between runs (§6). The eight stale `games` columns phase 1 left behind are still not dropped — that
remains its own separate migration, and it should wait until this phase is settled in production.
