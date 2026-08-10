# Game runs, phase 1: the schedule moves off `Game` — design

**Date:** 2026-08-10. **Decided by:** repository owner (`mezinster`), in session.

## 0. Why, and what this phase is not

A game that has finished cannot be played again. The author's remedy today is to create a second
game and re-enter every question, which duplicates content, splits the level history, and leaves two
games to maintain. The goal is to run the **same content** again for a **different set of teams**,
with the first cohort's results left exactly as they are.

Two findings decided the shape.

**The gameplay machinery already supports a late-arriving team.** `GamePassing`'s clock is per team,
not per game: `before_create :update_current_level_entered_at` stamps `Time.now` when a team first
opens the game, and every hint delay and level timer reads `current_level_entered_at`. Nothing is
anchored to `game.starts_at`. A team starting three months late already gets correct hint timing.

**But the standings are ranked by absolute wall-clock time.** `Game#place_of` compares
`effective_finished_at` (`finished_at + penalty_seconds`) — real timestamps. A team playing later
always finishes later in absolute time, so it always places last regardless of how fast it was.
Adding teams to a finished game would therefore produce a standings table that is wrong for the new
cohort, and would mix two events into one ranking.

The chosen model is that a **`Game` is content** (name, description, levels, hints, questions,
locales) and a **`GameRun` is one running of it** (schedule, capacity, finish, pause). Each run has
its own results.

That is a large change: `game_passings` is referenced at 133 call sites across 26 files, and eight
lifecycle columns are read across 17 files. It is therefore split into phases, each shipping working
software:

| # | Sub-project | Visible to users? |
|---|---|---|
| **1 — this spec** | `game_runs` exists; the schedule moves; `Game` delegates to its current run | **No.** Pure refactor. |
| 2 | Results, logs and stats become run-scoped | Barely — one run, so tables look identical |
| 3 | Superadmin opens a second run and admits teams; per-run results | **Yes — the feature** |
| 4 | *(optional)* Scheduling and announcing a run in advance | Yes |

**Phase 1 delivers no user-visible change by design.** Its success criterion is that nothing behaves
differently while the data has moved.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | Does a run own the schedule, or only group results? | **Owns the schedule.** `Game` becomes content; the run carries the event. |
| D2 | Which columns move? | The **eight scheduling columns**. Publication and moderation stay on `Game`. |
| D3 | How does it reach production? | **Expand now, contract later** — two deploys, real rollback between them. |
| D4 | Do the schedule validations move to `GameRun`? | **No, not in phase 1.** They stay on `Game`, reading delegated values. |

### D2 in full

**Moves to `game_runs`:** `starts_at`, `registration_deadline`, `max_team_number`,
`requested_teams_number`, `author_finished_at`, `is_testing`, `test_date`, `paused_at`.

**Stays on `games`:** `name`, `description`, `author_id`, `primary_locale`, `available_locales`,
`is_draft`, `withdrawn_at`, `editing_locked_at`.

The third group is the one worth justifying. `editing_locked_at` means "this author is under
investigation, freeze their content" and `withdrawn_at` means "unpublish this game" — neither is
about a single running of it, and an operator freezing a game under investigation means all of it,
not just the current cohort. `is_draft` gates whether the game is visible at all.

## 2. The model

```ruby
class GameRun < ApplicationRecord
  belongs_to :game
  # ordinal: 1-based, unique per game
  # starts_at, registration_deadline, max_team_number, requested_teams_number,
  # author_finished_at, is_testing, test_date, paused_at
end

class Game < ApplicationRecord
  has_many :runs, -> { order(:ordinal) }, :class_name => "GameRun", :dependent => :destroy

  def current_run
    runs.to_a.last || runs.build(:ordinal => 1)
  end

  delegate :starts_at, :starts_at=, :registration_deadline, :registration_deadline=,
           :max_team_number, :max_team_number=, :requested_teams_number,
           :requested_teams_number=, :author_finished_at, :author_finished_at=,
           :is_testing, :is_testing=, :test_date, :test_date=, :paused_at, :paused_at=,
           :to => :current_run
end
```

**`current_run` autobuilds rather than returning nil, and this is load-bearing.** Seventy places
across `spec/` and `features/` construct games as `Game.new(:starts_at => …, :max_team_number => …)`
before any run could exist; the delegated writer has to land somewhere. `has_many` autosaves new
children when the parent saves, so `create_game` and the game form keep working untouched.

**`runs.to_a.last`, not `runs.last`, and the difference is a bug not a style preference.**
`runs.last` on an unloaded association issues `SELECT … ORDER BY ordinal DESC LIMIT 1`, which cannot
see a record that has only been built in memory. So on a persisted game with no runs, the first call
would build a run, and the *second* call would query, find nothing, and build a **second** one —
`Game.new` then assigning two schedule attributes would produce two runs, and `has_many` autosave
would happily persist both. `to_a` calls `load_target`, which merges unsaved new records into the
loaded target, so the built run is visible to every later call.

**"Current" is the highest ordinal**, not "the one that is not finished". Deterministic, and it still
answers correctly in phase 3 when a second run exists.

`dependent: :destroy` matches `levels`: destroying a game destroys its runs. `Game#deletable?` still
refuses when `game_passings` exist, so this only ever fires on a game nobody has played.

## 3. Validations stay on `Game` (D4)

`game_starts_in_the_future`, `deadline_is_in_future`, `deadline_is_before_game_start` and
`valid_max_num` **do not move**. They stay on `Game` and read the delegated values.

Moving them to `GameRun` and promoting the errors up via the existing `ChildErrorPromotion` concern
was considered and rejected **for this phase**. `promotes_errors_from` adds child messages to
`:base`, so each error would move from its own field to the top-of-form list, and the message keys
would move from `activerecord.errors.models.game.attributes.*` to `…game_run.*` — four keys across
seven locale files, in a phase whose entire purpose is that nothing changes.

Keeping them on `Game` means phase 1 touches **no locale file, no form, and no error surface**.

`GameRun` gets its own validations in **phase 3**, when runs first become independently creatable and
a run can be saved without a game form in front of it. This is a deliberate deferral, recorded so it
is not rediscovered as an omission.

## 4. What changes in `app/`

| Thing | Change |
|---|---|
| `Game#status`, `started?`, `paused?`, `author_finished?`, `is_testing?` | **Source unchanged** — they read `starts_at` and friends, which now delegate |
| `Game.count_by_status` | **Rewritten.** It filters `games` columns in SQL, so it becomes a join to `game_runs` on the current run |
| `Game.started` / `Game.notstarted` | Unchanged — they load rows and call `started?` |
| `pause!`, `resume!`, `withdraw!`, `unfinish!`, `finish_game!`, `lock_editing!`, `unlock_editing!` | `withdraw!`, `restore!`, `lock_editing!`, `unlock_editing!` unchanged (their columns stay). `pause!`, `resume!`, `unfinish!`, `finish_game!` retarget their `update_column` to the run |
| `reserve_place_for_team!` / `free_place_of_team!` | Write `requested_teams_number` on the run |
| `game_passings`, `game_entries` | Gain `game_run_id`, backfilled. **Nothing reads it in phase 1** — that is phase 2 |

`count_by_status` is the only genuinely fiddly one. It exists because a counter must not load every
row, and its SQL precedence is pinned to `Game#status` by `spec/models/game/status_spec.rb`. That
pinning is what makes the rewrite verifiable rather than hopeful.

`update_column` on the run rather than the game keeps the reasoning already recorded on
`Game#withdraw!`: a running game fails its own validations, so a validated save would 422 on exactly
the games these methods exist for.

## 5. The migration

One migration in deploy 1, **expand only** — nothing dropped:

```
create_table :game_runs      → game_id, ordinal, the 8 columns, timestamps
add_column   :game_passings, :game_run_id
add_column   :game_entries,  :game_run_id
<backfill>
add_index    :game_runs, [:game_id, :ordinal], unique: true
add_index    :game_passings, :game_run_id
add_index    :game_entries,  :game_run_id
```

### The one dangerous line

**The backfill must not use the application's `Game` class.** By the time it runs, `Game#starts_at`
delegates to `current_run`, which autobuilds an empty run when none exists. So

```ruby
Game.find_each { |g| g.runs.create!(:starts_at => g.starts_at) }   # WRONG
```

reads `starts_at` **through the delegation**, off a freshly built empty run, and copies `nil` into
every row — silently destroying every schedule in the database. The migration succeeds, the app
boots, and every game simply has no start date.

The backfill therefore uses **raw SQL against the `games` table**, or migration-local model classes
with no delegation. It is three statements:

1. `INSERT INTO game_runs (game_id, ordinal, …) SELECT id, 1, … FROM games`
2. `UPDATE game_passings SET game_run_id = (SELECT id FROM game_runs WHERE game_runs.game_id = game_passings.game_id)`
3. the same for `game_entries`

All portable across SQLite (dev/test) and PostgreSQL (production). Every game gets a run whatever its
lifecycle state — draft, scheduled, running, finished, withdrawn — including games with
`NULL starts_at`, which produce a run with `NULL starts_at` and behave identically. Data volume is
tens of games; no batching.

Everything runs inside the migration's transaction, so a partial backfill cannot survive.

## 6. Rollback, and the one thing it does not cover

Reverting the code after deploy 1 restores the old behaviour: `games.starts_at` and its seven
neighbours are still present and still populated. No database restore is needed.

**Rollback is lossless only until someone edits a schedule.** Under the new code an author changing
a start date writes to `game_runs`; the stale `games.starts_at` is not updated. Revert after that and
the edit disappears — the row reverts to its pre-migration value. Nothing is corrupted, and no player
history is affected, but a schedule change is silently lost.

Dual-writing both copies through phase 1 would close this. It is **rejected**: it doubles the write
path for every schedule field, the two copies drift the moment anything writes one directly, and it
is code written solely to be deleted in deploy 2. The mitigation is a short window — verify, then
contract.

**Deploy 2** is one migration dropping the eight columns from `games`. After it the old code no
longer boots. That, not deploy 1, is the point of no return.

## 7. Testing

- **`GameRun`** — ordinal uniqueness scoped to the game; a run belongs to its game.
- **Delegation** — `Game.new(:starts_at => …)` before any run exists lands on the autobuilt run;
  saving the game persists it; reading it back returns it. This is the example protecting the 70
  construction sites in `spec/` and `features/`.
- **Exactly one run per autobuild** — a game built with *several* schedule attributes at once, and a
  persisted game whose schedule is assigned after load, each end up with **one** run, not one per
  assignment. This is the `runs.to_a.last` hazard in §2; without an example it fails as a duplicate
  row that only appears once a game is saved, and `create_game` passes both `:starts_at` and
  `:max_team_number`, so every fixture in the suite would hit it.
- **`count_by_status`** — the rewritten SQL still agrees with `Game#status` row by row, across all
  five statuses. `spec/models/game/status_spec.rb` already pins these two together.
- **Lifecycle methods on a started game** — `pause!`, `resume!`, `unfinish!` and `finish_game!` now
  write to the run; each needs an example on a game whose `starts_at` is in the past, for the reason
  recorded on `Game#withdraw!`: `create_game` defaults `starts_at` to 2099, so specs that do not
  arrange a started game prove nothing about the case these methods exist for.
- **Backfill invariant** — a spec asserting what the migration must leave behind: every game has
  exactly one run, every `game_passing` and `game_entry` carries a `game_run_id`.
- **Rehearsal against a copy of production data** before deploy. The real hazard is a game in a
  lifecycle state the fixtures never produce.
- **Cucumber must stay at exactly 232 scenarios / 2342 steps.** This is the real gate: the frozen
  scenarios drive game creation with `"Начало игры"` and `"Максимальное количество команд"`, the edit
  form, registration deadlines, and the whole play flow. If the delegation is wrong anywhere a player
  can reach, they fail.
- `db/schema.rb` is regenerated and committed; `bin/rails db:test:prepare` after.

## 8. Frozen acceptance surface

`features/**/*.feature` is not edited.

The constraint the frozen scenarios impose is on the **form, not the schema**:
`features/games/create-game.feature:83` and `:95` fill `"Начало игры"`, and `:25`, `:63`, `:73` fill
`"Максимальное количество команд"`, as literal Gherkin. Those fields must keep existing on the game
create/edit form and must keep saving. The delegation is what satisfies this — the form still posts
`game[starts_at]`, and the setter writes through to the run.

Everywhere else the schedule is reached through step definitions
(`назначает начало игры "X" на "Y"` in `features/games/steps/games_steps.rb:33`), which are editable
and are expected to need no change either, since they drive the same form.

No frozen scenario asserts any of the four validation messages that D4 leaves in place.

## 9. Out of scope

Nothing reads `game_run_id` on passings or entries in phase 1 — results, logs and stats stay
game-scoped until phase 2. No second run can be created; no UI mentions runs. `GameRun` has no
validations of its own until phase 3. The eight `games` columns are not dropped until deploy 2, which
is a separate one-migration change.
