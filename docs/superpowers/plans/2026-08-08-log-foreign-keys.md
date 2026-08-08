# Log Foreign Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `logs` real `team_id` and `level_id` columns, so every scope filters on an id instead
of a name — removing the ambiguity that produced two separate cross-game disclosures.

**Architecture:** Additive, in four stages, each independently revertable. The string columns
**stay**: they are the historical snapshot, they are what the live channel renders, and they are the
fallback for rows the backfill cannot resolve. New rows carry both. The scopes switch to ids with a
transitional name fallback bounded to one game, which is removed in the final task once the backfill
is verified against production.

**Tech Stack:** Rails 8.0, ActiveRecord migrations, sqlite in development/test and Postgres in
production, RSpec, Cucumber (Russian Gherkin).

## Global Constraints

- Ruby 3.3.12 via rbenv, **not on `PATH` in non-login shells**. Prefix every command with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never edit any file under `features/` ending in `.feature`.** Two amendments have been authorised
  in this repository's history and both are recorded in `CLAUDE.md`; this plan needs none.
- Subagents **cannot run Cucumber** — their Bash tool times out at 120s and the suite needs ~170s.
  Implementers run RSpec (~30s) and stop before committing; the controller runs Cucumber.
- Hash rockets (`:key => value`) throughout. Match the surrounding file.
- **Mutation-test every guard-style assertion** in the direction of the realistic regression. Four
  assertions in the preceding security work could not fail, and none was caught by inspection.
- Baseline on `master`: RSpec **944 examples / 0 failures / 6 pending**; Cucumber **232 scenarios
  (2 undefined, 230 passed) / 2342 steps**. Capture your own before starting.

## Facts established before writing this plan

Verified by reading the code, not assumed. They are what shaped the design:

- **The sole writer** is `GamePassingsController#save_log` (`:324`), called from two places (`:106`
  typed answers, `:187` quiz picks), both deliberately *before* `check_answer!`/`answer_options!` so
  the row is attributed to the level the answer was made on.
- **Only one view renders the strings:** `show_live_channel.html.erb:26-27`. The other three views use
  them purely as filters. `features/logs/live-channel.feature:58-74` asserts a team name and a level
  name appear on that page — so the rendered names must survive.
- **No `.feature` file asserts on a database column**, so adding columns breaks nothing frozen.
- **Level names are NOT unique within a game.** `app/models/level.rb:19` validates presence only; no
  index. `spec/spec_helpers/fixtures_helper.rb` defaults every level to `'Test level'`, and
  `spec/requests/quiz_play_spec.rb:119` creates two in one game. **This is the backfill hazard.**
- **Team names are globally unique in practice** — validated at `app/models/team.rb:7`, and there is
  no rename or destroy path for `Team` anywhere in the app. But there is **no unique index**, so a
  concurrent create could defeat it.
- **`logs` has no indexes at all**, not even on `game_id`.
- **`Game has_many :logs` has no `dependent:`** and is otherwise dead code. `Game#destroy` orphans log
  rows deliberately — see the comment at `app/models/game.rb:137-140`. **This plan does not add
  database-level foreign key constraints**, precisely because that would change `destroy` semantics;
  that is a separate product decision.

---

## Precondition — a production query only the owner can run

The backfill's safety depends on data this plan cannot see. **Before Task 2 is implemented**, run
these against production and record the results in the task-2 report:

```sql
-- level names that are ambiguous within their own game
SELECT l.game_id, l.name, COUNT(*)
FROM levels l GROUP BY l.game_id, l.name HAVING COUNT(*) > 1;

-- duplicate team names (the validation is app-level only)
SELECT name, COUNT(*) FROM teams GROUP BY name HAVING COUNT(*) > 1;

-- log rows whose level name does not resolve within their game
SELECT COUNT(*) FROM logs lo
WHERE NOT EXISTS (SELECT 1 FROM levels le WHERE le.game_id = lo.game_id AND le.name = lo.level);

-- log rows whose team name does not resolve at all
SELECT COUNT(*) FROM logs lo
WHERE NOT EXISTS (SELECT 1 FROM teams t WHERE t.name = lo.team);
```

If the first two return rows, the backfill will leave those `level_id`/`team_id` values NULL by
design — that is handled, not a blocker. But the counts must be **known and recorded**, because Task
4's decision to remove the name fallback depends on them.

---

## File Structure

**Created:** three migrations; `spec/models/log_spec.rb`; `spec/requests/log_backfill_spec.rb`.

**Modified:** `app/models/log.rb` (scopes), `app/controllers/game_passings_controller.rb`
(`save_log`), `app/controllers/logs_controller.rb` (nil guard, preload),
`app/views/logs/show_live_channel.html.erb` (render from associations with fallback),
`spec/requests/quiz_play_spec.rb`, `spec/views/logs_spec.rb`, `db/schema.rb`.

---

### Task 1: Add the columns and indexes; write both representations

**Files:**
- Create: `db/migrate/<timestamp>_add_team_and_level_ids_to_logs.rb`
- Modify: `app/controllers/game_passings_controller.rb` (`save_log`, ~`:320-326`)
- Modify: `app/models/log.rb` (associations only — **not** the scopes yet)
- Test: `spec/models/log_spec.rb` (create)

**Interfaces:**
- Produces: `logs.team_id`, `logs.level_id` (both nullable integers), `Log#team_record`,
  `Log#level_record`. Tasks 2-4 consume them.

**Why the scopes do not change in this task:** so that this task is provably behaviour-neutral. New
rows gain ids; nothing yet reads them. If anything breaks here, it is the writer, not the readers.

- [ ] **Step 1: Write the failing test**

Create `spec/models/log_spec.rb`:

```ruby
require "rails_helper"

# logs.team and logs.level are name strings, which is why every scope except
# of_game was globally ambiguous and produced two cross-game disclosures. The
# ids are additive: the strings stay as the historical snapshot and as what the
# live channel renders.
describe Log do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  it "carries both the id and the name for a level" do
    log = Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                      :team => team.name, :team_id => team.id,
                      :time => Time.now, :answer => "код")

    expect(log.reload.level_id).to eq(level.id)
    expect(log.level).to eq(level.name)
    expect(log.level_record).to eq(level)
    expect(log.team_record).to eq(team)
  end

  it "tolerates a row whose ids were never backfilled" do
    log = Log.create!(:game_id => game.id, :level => "Старое задание",
                      :team => "Старая команда", :time => Time.now, :answer => "код")

    expect(log.reload.level_record).to be_nil
    expect(log.team_record).to be_nil
    expect(log.level).to eq("Старое задание")
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/log_spec.rb
```

Expected: failures on the unknown attributes `level_id`/`team_id`.

- [ ] **Step 3: Migration**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails generate migration AddTeamAndLevelIdsToLogs
```

```ruby
class AddTeamAndLevelIdsToLogs < ActiveRecord::Migration[8.0]
  # Deliberately no foreign key constraints. Game#destroy currently orphans log
  # rows on purpose (see the comment on Game#deletable?), and a database-level
  # constraint would turn that into an exception. Whether logs should cascade is
  # a product decision, not part of this change.
  #
  # Both columns are nullable: the backfill cannot resolve a level name that is
  # ambiguous within its game, and level names have no uniqueness constraint.
  def change
    add_column :logs, :team_id,  :integer
    add_column :logs, :level_id, :integer

    # logs had no indexes at all -- not even on game_id -- while show_full_log
    # queries it once per (level x team) inside nested loops.
    add_index :logs, [ :game_id, :team_id, :level_id ]
  end
end
```

```bash
bin/rails db:migrate && bin/rails db:test:prepare
```

**If `db:migrate` is denied by the sandbox permission classifier, STOP and report it. Do not
hand-edit `db/schema.rb`** — that bypass happened during the security work and had to be disclosed
in a pull request.

- [ ] **Step 4: Associations, and the writer**

`app/models/log.rb` — add associations only, leave the scopes untouched:

```ruby
  # Named _record because `team` and `level` are already the snapshot columns.
  belongs_to :team_record,  :class_name => "Team",  :foreign_key => "team_id",  :optional => true
  belongs_to :level_record, :class_name => "Level", :foreign_key => "level_id", :optional => true
```

`GamePassingsController#save_log` — write both representations:

```ruby
    Log.create!(game_id: @game.id,
                level: level.name, level_id: level.id,
                team: @team.name,  team_id: @team.id,
                time: Time.now, answer: @answer)
```

- [ ] **Step 5: Verify, then hand over for Cucumber**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
```

Expected: baseline + 2. Then stop and report ready — the controller runs Cucumber, which must be
exactly at baseline since nothing reads the new columns yet.

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/log.rb app/controllers/game_passings_controller.rb spec/models/log_spec.rb
git commit -m "Give log rows a team_id and a level_id alongside the names

The name strings are what made every scope except of_game globally ambiguous,
which produced two separate cross-game disclosures. New rows now carry both
representations; nothing reads the ids yet, so this change is behaviour-neutral
by construction.

The strings stay: they are the historical snapshot, they are what the live
channel renders, and they are the fallback for rows the backfill cannot
resolve. No foreign key constraints -- Game#destroy orphans logs deliberately
and a constraint would turn that into an exception."
```

---

### Task 2: Backfill, reporting what it could not resolve

**Files:**
- Create: `db/migrate/<timestamp>_backfill_log_team_and_level_ids.rb`
- Test: `spec/requests/log_backfill_spec.rb` (create)

**Interfaces:**
- Consumes: the columns from Task 1.
- Produces: populated ids for every row whose names resolve unambiguously.

**Do not start until the production query in the Precondition section has been run and its results
recorded in your report.**

- [ ] **Step 1: Write the failing test**

Create `spec/requests/log_backfill_spec.rb`. It exercises the backfill logic directly rather than the
migration class, so it can assert the ambiguous case:

```ruby
require "rails_helper"

# Team names are globally unique in practice (validated, and Team has no rename
# or destroy path), so those resolve. Level names are NOT unique within a game
# -- Level validates presence only -- so an ambiguous name must be left NULL
# rather than guessed at.
describe "backfilling log ids", type: :request do
  let(:game) { create_game }

  it "resolves an unambiguous level name within its own game" do
    level = create_level(:game => game, :name => "Уникальное задание")
    team  = create_team(:captain => create_user)
    log   = Log.create!(:game_id => game.id, :level => level.name,
                        :team => team.name, :time => Time.now, :answer => "код")

    Log.backfill_ids!

    expect(log.reload.level_id).to eq(level.id)
    expect(log.team_id).to eq(team.id)
  end

  it "leaves a level name that is ambiguous within its game NULL" do
    first  = create_level(:game => game, :name => "Одинаковое")
    create_level(:game => game, :name => "Одинаковое")
    team   = create_team(:captain => create_user)
    log    = Log.create!(:game_id => game.id, :level => "Одинаковое",
                         :team => team.name, :time => Time.now, :answer => "код")

    Log.backfill_ids!

    expect(log.reload.level_id).to be_nil
    expect(log.team_id).to eq(team.id)
    expect(first).to be_present
  end

  it "does not match a level of the same name in a different game" do
    other_level = create_level(:name => "Общее имя")
    log = Log.create!(:game_id => game.id, :level => "Общее имя",
                      :team => "Нет такой команды", :time => Time.now, :answer => "код")

    Log.backfill_ids!

    expect(log.reload.level_id).to be_nil
    expect(other_level.game_id).not_to eq(game.id)
  end
end
```

- [ ] **Step 2: Run it and confirm it fails** — `Log.backfill_ids!` does not exist.

- [ ] **Step 3: Implement `Log.backfill_ids!`**

Put it on the model, not in the migration, so it is testable and re-runnable:

```ruby
  # Idempotent and safe to re-run: only touches rows whose id is still NULL.
  # Returns the counts, which the migration logs -- a silent backfill that
  # resolved nothing would otherwise look identical to one that resolved
  # everything.
  def self.backfill_ids!
    resolved_teams = 0
    resolved_levels = 0
    ambiguous_levels = 0

    find_each do |log|
      if log.team_id.nil?
        matches = Team.where(:name => log.team).limit(2).to_a
        if matches.length == 1
          log.update_column(:team_id, matches.first.id)
          resolved_teams += 1
        end
      end

      next unless log.level_id.nil?

      matches = Level.where(:game_id => log.game_id, :name => log.level).limit(2).to_a
      if matches.length == 1
        log.update_column(:level_id, matches.first.id)
        resolved_levels += 1
      elsif matches.length > 1
        ambiguous_levels += 1
      end
    end

    { :teams => resolved_teams, :levels => resolved_levels, :ambiguous => ambiguous_levels }
  end
```

- [ ] **Step 4: The migration calls it and reports**

```ruby
class BackfillLogTeamAndLevelIds < ActiveRecord::Migration[8.0]
  def up
    counts = Log.backfill_ids!
    say "backfilled #{counts[:teams]} team_id and #{counts[:levels]} level_id values"
    say "left #{counts[:ambiguous]} row(s) NULL: their level name is ambiguous within its own game"
    say "logs still missing level_id: #{Log.where(:level_id => nil).count}"
    say "logs still missing team_id:  #{Log.where(:team_id => nil).count}"
  end

  def down
    Log.update_all(:team_id => nil, :level_id => nil)
  end
end
```

`down` is genuinely reversible here — it clears columns the previous migration added and no other
code has written to. Say so in the commit rather than leaving a reader to work it out.

- [ ] **Step 5: Run, verify, hand over for Cucumber, commit**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate && bin/rails db:test:prepare && bundle exec rspec
```

Record the migration's own output in your report — the counts are the evidence, and they decide
Task 4.

---

### Task 3: Switch the scopes to ids, with a bounded name fallback

**Files:**
- Modify: `app/models/log.rb` (scopes), `app/controllers/logs_controller.rb`,
  `app/views/logs/show_live_channel.html.erb`
- Modify: `spec/requests/quiz_play_spec.rb` (`:126`, `:138`), `spec/views/logs_spec.rb`
- Test: extend `spec/requests/game_log_scope_spec.rb` and `full_log_scope_spec.rb`

**This is the task that delivers the security property.** Read the whole task before starting.

- [ ] **Step 1: Write the failing test**

Add to `spec/requests/game_log_scope_spec.rb` an example proving id-scoping holds even when names
collide — the case the old code could not distinguish:

```ruby
  it "does not show a same-named level's rows from another game" do
    other_game  = create_game
    other_level = create_level(:game => other_game, :name => level.name)
    Log.create!(:game_id => other_game.id, :level => other_level.name,
                :level_id => other_level.id, :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "ЧУЖОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖОЙ-КОД")
  end
```

- [ ] **Step 2: Switch the scopes**

```ruby
  scope :of_game,  ->(game)  { where(game_id: game) }

  # id-scoped, with a fallback for rows the backfill could not resolve (a level
  # name that is ambiguous within its own game). Every caller chains of_game
  # first, so the fallback is bounded to one game and cannot reach across games
  # the way the bare name match did. Task 4 removes it once production is
  # confirmed clean.
  scope :of_team,  ->(team) {
    where("logs.team_id = :id OR (logs.team_id IS NULL AND logs.team = :name)",
          :id => team.id, :name => team.name)
  }
  scope :of_level, ->(level) {
    where("logs.level_id = :id OR (logs.level_id IS NULL AND logs.level = :name)",
          :id => level.id, :name => level.name)
  }
```

**Verify the fallback is genuinely bounded** by checking every caller chains `of_game` first —
`logs_controller.rb:32,36,40,44` and the two views that re-scope. Report what you find; if any caller
does not, say so rather than assuming the comment is true.

- [ ] **Step 3: Fix the latent nil crash while you are here**

`logs_controller.rb:62` sets `@level = @team.current_level_in(@game)`, and `GamePassing#pass_level!`
nils `current_level` when a team finishes. So `show_level_log` for a finished team currently calls
`of_level(nil)` → `NoMethodError` → 500. It is reachable only by direct URL.

Under the new scope that would become `where(level_id: nil)` and silently return the wrong rows —
strictly worse than the crash. Add an explicit guard that renders an empty log rather than inheriting
the change by accident, and add an example for it.

- [ ] **Step 4: Keep the live channel rendering names**

`show_live_channel.html.erb:26-27` prints `log.team` and `log.level`, and
`features/logs/live-channel.feature:58-74` asserts a team name and a level name appear. Prefer the
association, fall back to the snapshot:

```erb
    <td><%= log.team_record&.name || log.team %></td>
    <td><%= log.level_record&.name || log.level %></td>
```

Add `includes(:team_record, :level_record)` to `logs_controller.rb:32` — that view renders every row
of a game.

- [ ] **Step 5: Update the two specs that assert on the string**

`spec/requests/quiz_play_spec.rb:126,138` assert `Log.last.level == level.name`. They were written to
catch a real attribution bug — the row must name the level the answer was made *on*, not the one
advanced to. **Preserve that intent**: assert `Log.last.level_id == level.id` and keep the name
assertion too, since both representations are written now.

- [ ] **Step 6: Verify by mutation**

Revert the scopes to the name-only form, confirm the new cross-game example fails, restore. Report
both runs. Then run RSpec and hand over for Cucumber — `features/logs/` is the binding surface and
must be exactly at baseline.

- [ ] **Step 7: Commit**

---

### Task 4: Remove the fallback, once production says it is safe

**Do not start this task until Task 2's migration has run against production and its reported counts
are known.**

If `ambiguous` is 0 and both "still missing" counts are 0, the fallback is dead code: delete it,
leaving `where(team_id: team.id)` and `where(level_id: level.id)`, and add a spec asserting a row
with a NULL id is **not** returned.

If the counts are non-zero, **stop and report them.** Leaving the fallback is the correct outcome —
but it must be a recorded decision with the numbers attached, not an omission. Update the comment in
`app/models/log.rb` to state how many rows depend on it and why they could not be resolved.

---

## Definition of done

- Both suites at baseline plus the new examples; `features/logs/` unchanged and passing.
- No `.feature` file modified — check `git status features/`.
- The backfill migration's counts recorded in the task-2 report and carried into the PR description.
- Task 4 either removed the fallback or recorded why it stays, with numbers.

## Explicitly out of scope

- **Foreign key constraints.** They would turn `Game#destroy`'s deliberate orphaning into an
  exception. Separate product decision.
- **A unique index on `teams.name`.** Real (the validation is app-level only) but it belongs with
  follow-up item #4, `GameEntry` uniqueness.
- **Per-game uniqueness for `Level#name`.** It would remove the ambiguity at source, but it is a
  product constraint on authors and may invalidate existing games.
- **The raw interpolated SQL at `logs_controller.rb:46-48`.** `@game.id` is an integer from
  `Game.find`, so it is not injectable; it sits in a method this plan touches but is not part of it.
