# Game runs, phase 2: results, logs and stats become run-scoped — design

**Date:** 2026-08-10. **Decided by:** repository owner (`mezinster`), in session.

## 0. Where this sits

Phase 1 (`docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md`, merged as PR #68 and
deployed) moved the schedule off `games` onto `game_runs`, and gave `game_passings` and
`game_entries` a backfilled `game_run_id` that **nothing reads**. This phase makes the read paths
use it.

| # | Sub-project | Visible? |
|---|---|---|
| 1 — done | `game_runs` exists; the schedule moves; `Game` delegates | No |
| **2 — this spec** | Results, logs and stats become run-scoped | **No** |
| 3 | Superadmin opens a second run and admits teams | **Yes — the feature** |

**Phase 2 is invisible for the same reason phase 1 was**: every production game has exactly one run,
so every scoped query returns precisely what the game-scoped one returned. That property is also
this phase's central testing problem — see §6.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | How does a log row know its run? | **Its own `game_run_id` column**, backfilled — not derived through the passing. |
| D2 | Where do the run-aware read methods live? | **On `GameRun`.** `Game` keeps one-line delegations to `current_run`. |
| D3 | Does `GameEntry` become run-scoped? | **No.** Registration is admission to a run, which is phase 3's subject. |

### Why D1

Deriving a log's run — team + game → passing → run — is correct only while a game has one run. In
phase 3 a team can hold a passing in two runs of the same game, and the join becomes ambiguous
exactly where it matters: an author watching run 2's live channel would see run 1's answers mixed
in. A column states the fact instead of inferring it.

The precedent is `Log.backfill_ids!` and the 2026-08-08 log foreign-keys work: add the column,
backfill idempotently over `NULL` rows only, return counts. Production holds **162 log rows**, so
the backfill is instant.

### Why D2

`place_of` has exactly one application call site and `finished_teams` one, so moving them is cheap
now and saves moving them during phase 3, which has the most moving parts. Phase 3 then asks
`run.place_of(team)` for whichever run it means, rather than needing a second way to ask.

## 2. Logs

```
logs
  + game_run_id            (integer, indexed)

Log.of_run(run)            scope
Log.backfill_run_ids!      idempotent; touches only NULL rows; returns counts
```

The backfill resolves a log's run **from its `game_id` alone**, because today every log of a game
belongs to that game's only run:

```sql
UPDATE logs SET game_run_id = (SELECT id FROM game_runs WHERE game_runs.game_id = logs.game_id)
 WHERE game_run_id IS NULL AND game_id IS NOT NULL
```

That is exactly correct now and would be ambiguous once a second run exists — which is the whole
reason the column is being added rather than the join being written into the views.

Logs are written in one place, `GamePassingsController#save_log`, which sets
`game_run_id: @game_passing.game_run_id`. Taking it from the passing rather than from
`@game.current_run` matters: the passing is what the answer actually belongs to.

## 3. The read methods move to `GameRun`

```ruby
class GameRun
  has_many :passings, :class_name => "GamePassing"

  def passing_for(team)   # replaces GamePassing.of(team, game)
  def finished_teams
  def place_of(team)      # ranks within THIS run only
end
```

Ranking **within** a run stays exactly as it is — `effective_finished_at`, an absolute timestamp,
compared across that run's finished passings. Teams already choose when to start after `starts_at`,
so absolute-time ranking mildly favours whoever opened the game earliest, and this phase does not
change that. It is a pre-existing property, not something run-scoping introduces or fixes, and it is
recorded here only so a reader does not assume otherwise.

```ruby
class Game
  def place_of(team)      = current_run.place_of(team)
  def finished_teams      = current_run.finished_teams
end
```

`GamePassing.of(team, game)` is **removed**, not kept alongside. Its five call sites become
`run.passing_for(team)`:

| Call site | Was |
|---|---|
| `Team#current_level_in(game)` | `GamePassing.of(self, game)` |
| `Team#finished?(game)` | `GamePassing.of(self, game)` |
| `GamePassingsHelper` (:47) | `GamePassing.of(current_user.team, game)` |
| `LogsController` (:98) | `GamePassing.of(current_user.team, @game)` |
| `GamePassingsController#find_or_create_game_passing` | `GamePassing.of(@team, @game)` |

Two ways to ask one question is how the stale one survives.

`Team#current_level_in(game)` and `Team#finished?(game)` keep taking a **game** — they are asked
from screens that know a game, not a run — and reach `game.current_run.passing_for(self)`.

## 4. The write path, and one new guard

`find_or_create_game_passing` creates with `:game_run => @game.current_run`.

A **unique index on `(team_id, game_run_id)`** is added. One passing per team per run is the real
invariant and today nothing enforces it but the `find_or_create` read — a double-submitted first
request can create two.

It is added the way `game_entries`' live-status index was
(`db/migrate/20260808070000_add_unique_index_to_game_entries_on_team_and_game.rb`): **check for
duplicates first, and `say` rather than raise if any exist.** Migrations run under `db:prepare`
before puma starts, so an index that raises on unexpected data takes the whole app down mid-deploy,
recoverable only by someone shelling in. Production currently has 3 passings, so this will not fire
— the guard is for restored or future data.

## 5. The remaining `of_game` call sites

| Site | Becomes |
|---|---|
| `game_passings/show_results.html.erb:17` | the run's passings |
| `GamePassingsController#index` (:65) | the run's passings |
| `LogsController` :32, :47, :51, :55 | `Log.of_run(run)` |
| `InterventionsController:84` | the run's passing for that team |
| `Game#resume!` (:190) | the run's unfinished passings — only the current run has running clocks |
| `GamesController#end_game` (:90) | the run's passings |
| `GamesController#finish_test` (:216-217) | the run's passings and logs |

`finish_test` matters more than its size suggests: it deletes player history, and in phase 3 a test
run must not erase a real run's results.

**`Game#deletable?` stays game-scoped, deliberately.** It refuses deletion while `game_passings`
exist, and that has to mean *any* run's history — a game whose first run was played is not deletable
because its second run happens to be empty.

Nothing hard-codes "the only run": every site takes a run or reads `current_run`.

**Which run do the screens use?** All of them resolve `@game.current_run`, because every one of them
is reached by a URL carrying a game id and no run id. Phase 3 is what introduces a URL that names a
run; until then "the game's current run" is the only answer any of these screens could give, and
saying so here stops it being re-derived per view.

## 6. Testing — the isolation specs are the deliverable

**With one run per game, every scoped query returns what the unscoped one returned, so a green suite
proves nothing.** The specs must build the second run themselves; nothing in the application can yet.

For each of `place_of`, `finished_teams`, the passings list, each log screen and `finish_test`:
create a game, create a second `GameRun` on it directly, put a passing (and a log) in each run, and
assert that the run 1 view contains only run 1's rows.

**`place_of` gets a mutation-check beyond that.** Give run 1 a team that finished *earlier in
absolute wall-clock time* than every team in run 2, then assert run 2's ranking is unaffected by it.
Absolute-time ranking across cohorts is the original defect this whole programme exists to fix, so it
is pinned explicitly rather than trusted to fall out of the scoping.

Also:

- **Log backfill invariant** — every log with a `game_id` ends with a `game_run_id`; re-running
  resolves nothing and reports zero.
- **The unique index guard** — exercised against a table that *does* contain duplicates, proving the
  migration says so and completes rather than raising. A guard that has only ever run against clean
  data is untested.
- **Delegation** — `Game#place_of` and `#finished_teams` agree with `current_run`'s.
- **Cucumber must stay at exactly 232 scenarios / 2342 steps.** The frozen scenarios drive the
  results table, the live channel and the log screens, so this is a real gate here rather than a
  formality.

## 7. Frozen surface and invisibility

No `features/**/*.feature` file is edited. No locale key is added or changed — nothing user-visible
gains or loses text. Every production game has one run, so every screen renders identically.

## 8. Out of scope

`GameEntry` stays game-scoped until phase 3, when admission to a run is designed. No UI mentions
runs, and no second run can be created outside a spec. `Game#place_of` and `#finished_teams` keep
their signatures through delegation, so no caller outside the files listed above changes. Nothing
here drops the eight `games` columns phase 1 left behind — that remains its own separate migration.
