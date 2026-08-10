# Game Runs, Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the eight scheduling columns off `games` onto a new `game_runs` table, with `Game` delegating to its current run, changing nothing a user can see.

**Architecture:** A `GameRun` is one running of a game. `Game` gains `has_many :runs` and a `current_run` that autobuilds, and delegates the eight schedule accessors to it. The migration is **expand-only** — it creates and backfills, and drops nothing, so reverting the code is a complete rollback. Dropping the old columns is a separate later change, out of scope here.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec, sqlite in dev/test, PostgreSQL in production. Migrations run automatically on deploy via `bin/docker-entrypoint`'s `db:prepare` before puma starts.

**Spec:** `docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix every command with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any file under `features/`.** Not even whitespace. This plan touches none.
- **Cucumber must stay at exactly 232 scenarios (230 passed, 2 undefined) / 2342 steps** after every task. This is the real gate: frozen scenarios drive game creation with `"Начало игры"` and `"Максимальное количество команд"`, the edit form, registration deadlines, and the whole play flow.
- **Phase 1 is invisible.** No locale file, no view, and no controller changes. If a task needs one, stop — the design is wrong, not the code.
- **The eight moving columns:** `starts_at`, `registration_deadline`, `max_team_number`, `requested_teams_number`, `author_finished_at`, `is_testing`, `test_date`, `paused_at`.
- **The columns that stay on `games`:** `name`, `description`, `author_id`, `primary_locale`, `available_locales`, `is_draft`, `withdrawn_at`, `editing_locked_at`. **Do not touch `withdrawn_at` or `editing_locked_at` anywhere in this plan** — several specs `update_column` them, and those call sites are correct as they stand.
- **Hash-rocket style** (`:key => value`) throughout, matching the surrounding files. Comments in English, user-facing strings in Russian.
- Run `bin/rails db:test:prepare` after the migration task, as in any Rails app.
- Commit after every task.

---

### Task 1: The `game_runs` table, the model, and the backfill

Creates and populates the table. **Nothing reads it yet**, so the suite must stay green on code that is entirely unaware runs exist.

**Files:**
- Create: `db/migrate/20260810120000_create_game_runs.rb`
- Create: `app/models/game_run.rb`
- Create: `spec/models/game_run_spec.rb`
- Create: `spec/models/game_run/backfill_spec.rb`
- Modify: `db/schema.rb` (regenerated, not hand-edited)

**Interfaces:**
- Produces: `GameRun` with `game_id`, `ordinal`, and the eight schedule columns. `game_passings.game_run_id` and `game_entries.game_run_id`, backfilled. Task 2 consumes `GameRun` via `Game#runs`.

- [ ] **Step 1: Write the failing model spec**

Create `spec/models/game_run_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# One running of a game. Phase 1 only creates these by backfill and by Game's
# autobuild; nothing yet reads them. See
# docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md.
RSpec.describe GameRun do
  let(:game) { create_game }

  it "belongs to a game" do
    run = GameRun.create!(:game => game, :ordinal => 1)

    expect(run.game).to eq(game)
  end

  it "refuses a run with no game" do
    expect(GameRun.new(:ordinal => 1)).not_to be_valid
  end

  it "refuses a second run with the same ordinal in one game" do
    GameRun.create!(:game => game, :ordinal => 1)

    expect(GameRun.new(:game => game, :ordinal => 1)).not_to be_valid
  end

  # Ordinals are per game, not global -- two different games each have a run 1.
  it "allows the same ordinal in a different game" do
    GameRun.create!(:game => game, :ordinal => 1)

    expect(GameRun.new(:game => create_game, :ordinal => 1)).to be_valid
  end

  it "refuses a non-positive ordinal" do
    expect(GameRun.new(:game => game, :ordinal => 0)).not_to be_valid
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game_run_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant GameRun`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260810120000_create_game_runs.rb`:

```ruby
# Phase 1 of separating a game's CONTENT from one RUNNING of it. Expand only:
# this creates and backfills, and drops nothing, so reverting the application
# code is a complete rollback with the games columns still populated. Dropping
# them is a separate, later migration.
#
# See docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md.
class CreateGameRuns < ActiveRecord::Migration[8.0]
  def up
    create_table :game_runs do |t|
      t.integer  :game_id, :null => false
      t.integer  :ordinal, :null => false, :default => 1
      t.datetime :starts_at, :precision => nil
      t.datetime :registration_deadline, :precision => nil
      t.integer  :max_team_number
      t.integer  :requested_teams_number, :default => 0
      t.datetime :author_finished_at, :precision => nil
      t.boolean  :is_testing, :null => false, :default => false
      t.datetime :test_date, :precision => nil
      t.datetime :paused_at
      t.timestamps
    end

    add_column :game_passings, :game_run_id, :integer
    add_column :game_entries,  :game_run_id, :integer

    # RAW SQL, DELIBERATELY, AND THIS IS THE MOST DANGEROUS LINE IN THE PHASE.
    #
    # Once the application code lands, Game#starts_at delegates to current_run,
    # which AUTOBUILDS an empty run when none exists. So the obvious form --
    #
    #   Game.find_each { |g| g.runs.create!(:starts_at => g.starts_at) }
    #
    # -- reads starts_at THROUGH the delegation, off a freshly built empty run,
    # and copies nil into every row: every schedule in the database silently
    # destroyed, with the migration reporting success and the app booting fine.
    # Going straight at the table cannot do that.
    execute <<~SQL
      INSERT INTO game_runs (game_id, ordinal, starts_at, registration_deadline,
                             max_team_number, requested_teams_number,
                             author_finished_at, is_testing, test_date, paused_at,
                             created_at, updated_at)
      SELECT id, 1, starts_at, registration_deadline,
             max_team_number, requested_teams_number,
             author_finished_at, is_testing, test_date, paused_at,
             created_at, updated_at
        FROM games
    SQL

    # Correlated subquery rather than a JOIN in UPDATE: portable across SQLite
    # (dev/test) and PostgreSQL (production), which disagree on UPDATE ... FROM.
    #
    # game_passings.game_id is nullable (belongs_to :game, optional: true), so a
    # row with no game keeps a NULL game_run_id. That is correct, not a miss.
    execute <<~SQL
      UPDATE game_passings
         SET game_run_id = (SELECT gr.id FROM game_runs gr
                             WHERE gr.game_id = game_passings.game_id)
    SQL

    execute <<~SQL
      UPDATE game_entries
         SET game_run_id = (SELECT gr.id FROM game_runs gr
                             WHERE gr.game_id = game_entries.game_id)
    SQL

    add_index :game_runs, [ :game_id, :ordinal ], :unique => true
    add_index :game_passings, :game_run_id
    add_index :game_entries, :game_run_id
  end

  def down
    remove_column :game_entries, :game_run_id
    remove_column :game_passings, :game_run_id
    drop_table :game_runs
  end
end
```

- [ ] **Step 4: Write the model**

Create `app/models/game_run.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# One running of a game. A Game is the CONTENT -- name, description, levels,
# hints, questions, locales -- and a GameRun is one event over that content:
# when it starts, how many teams it takes, when the author ended it.
#
# Phase 1 creates these only by backfill and by Game's autobuild, and nothing
# reads game_run_id on passings or entries yet; results, logs and stats stay
# game-scoped until phase 2.
#
# No schedule validations here yet, deliberately. They stay on Game through
# phase 1 (see the design, D4) because moving them would push each error from
# its own form field to :base and rename four message keys across seven locale
# files -- in a phase whose entire point is that nothing changes. A run first
# becomes creatable without a game form in front of it in phase 3, and that is
# when it needs its own.
class GameRun < ApplicationRecord
  # optional: true plus an explicit presence validation, matching Game's own
  # belongs_to :author -- the established shape in this codebase.
  #
  # inverse_of: :runs is added here at the same time as Game's has_many, not
  # before it: Rails resolves the named inverse eagerly and raises
  # InverseOfAssociationNotFoundError if the other side does not exist yet.
  # It is not merely a nicety once both sides are declared -- Game's has_many
  # carries a scope (-> { order(:ordinal) }) and its name does not match this
  # class, and each of those independently defeats Rails' automatic inverse
  # detection. Without it an autobuilt run on an unsaved game cannot see its
  # parent, and the presence validation below fails on every new game.
  belongs_to :game, :optional => true

  validates :game, presence: true
  validates :ordinal, presence: true,
                      numericality: { greater_than: 0 },
                      uniqueness: { scope: :game_id }
end
```

- [ ] **Step 5: Migrate and run the model spec**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
bundle exec rspec spec/models/game_run_spec.rb
```

Expected: PASS, 5 examples, 0 failures. `db/schema.rb` is regenerated by `db:migrate` — commit it, do not hand-edit it.

- [ ] **Step 6: Write the backfill invariant spec**

The migration has already run against the dev and test databases, both of which were empty of pre-existing games, so this spec asserts the invariant rather than replaying the migration. Create `spec/models/game_run/backfill_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# What the backfill must leave behind, expressed as an invariant rather than by
# replaying the migration: every game has a run, and every passing and entry
# that belongs to a game points at one.
#
# Rehearse the migration itself against a COPY OF PRODUCTION before deploying.
# The real hazard is a game in a lifecycle state the fixtures never produce, and
# no spec here can stand in for that.
RSpec.describe "the game_runs backfill invariant" do
  it "gives the migration's INSERT one run per game, copying the schedule" do
    # Reproduces exactly what the migration's INSERT ... SELECT does, against a
    # game written the pre-migration way: columns set on games, no run.
    game = create_game
    game.runs.delete_all if game.respond_to?(:runs)
    ActiveRecord::Base.connection.execute(<<~SQL)
      UPDATE games SET starts_at = '2031-05-05 10:00:00', max_team_number = 42
       WHERE id = #{game.id}
    SQL
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO game_runs (game_id, ordinal, starts_at, max_team_number,
                             requested_teams_number, is_testing,
                             created_at, updated_at)
      SELECT id, 1, starts_at, max_team_number, requested_teams_number, is_testing,
             created_at, updated_at
        FROM games WHERE id = #{game.id}
    SQL

    run = GameRun.where(:game_id => game.id).order(:ordinal).last
    expect(run.ordinal).to eq(1)
    expect(run.max_team_number).to eq(42)
    expect(run.starts_at).not_to be_nil
  end

  # A game with no start time is a real state -- Game#started? treats NULL as
  # not started, and count_by_status has an explicit NULL branch for it. The
  # backfill must carry the NULL through rather than skipping the row.
  it "gives a game with no start time a run, with a null start time" do
    game = create_game
    ActiveRecord::Base.connection.execute("UPDATE games SET starts_at = NULL WHERE id = #{game.id}")
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO game_runs (game_id, ordinal, starts_at, requested_teams_number,
                             is_testing, created_at, updated_at)
      SELECT id, 99, starts_at, requested_teams_number, is_testing, created_at, updated_at
        FROM games WHERE id = #{game.id}
    SQL

    run = GameRun.where(:game_id => game.id, :ordinal => 99).first
    expect(run).to be_present
    expect(run.starts_at).to be_nil
  end
end
```

- [ ] **Step 7: Run the whole suite — nothing may have changed**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec 0 failures (the count rises by the 7 new examples). Cucumber **232 scenarios (230 passed, 2 undefined), 2342 steps**. Nothing reads the new table yet, so any change here is a real regression.

- [ ] **Step 8: Commit**

```bash
git add db/migrate app/models/game_run.rb spec/models/game_run_spec.rb spec/models/game_run/backfill_spec.rb db/schema.rb
git commit -m "Add game_runs and backfill one run per game

Expand only: nothing is dropped, so reverting the code is a complete
rollback with the games columns still populated. The backfill goes
straight at the table in SQL rather than through Game, because once the
delegation lands Game#starts_at reads through an autobuilt empty run --
the obvious ActiveRecord form would copy nil into every row and report
success."
```

---

### Task 2: `Game#runs`, `current_run`, and routing the spec arrangements through a helper

Adds the association and the autobuild, and moves all 59 spec arrangements onto a helper that writes **both** the old columns and the run. The old columns are still authoritative, so the suite stays green — and Task 3 can then flip the delegation without touching 59 files.

**Files:**
- Modify: `app/models/game.rb` (add `has_many :runs` and `current_run` near the other associations, around line 17)
- Modify: `spec/spec_helpers/fixtures_helper.rb`
- Modify: 20 spec files (list in Step 4)
- Test: `spec/models/game/current_run_spec.rb` (create)

**Interfaces:**
- Consumes: `GameRun` from Task 1.
- Produces: `Game#runs` (ordered by `ordinal`, `autosave: true`, `dependent: :destroy`) and `Game#current_run` → the highest-ordinal run, autobuilt with `ordinal: 1` when none exists. `set_game_schedule!(game, attrs)` in `FixturesHelper`. Task 3 delegates to `current_run`.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/game/current_run_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe Game, "#current_run" do
  it "autobuilds a first run for a game that has none" do
    game = create_game
    game.runs.delete_all
    game.reload

    expect(game.current_run).to be_a(GameRun)
    expect(game.current_run.ordinal).to eq(1)
  end

  # THE hazard. runs.last on an unloaded association issues
  # SELECT ... ORDER BY ordinal DESC LIMIT 1, which cannot see a record that
  # only exists in memory -- so a second call would build a SECOND run, and
  # autosave would persist both. runs.to_a calls load_target, which merges
  # unsaved records into the loaded target.
  #
  # create_game passes both :starts_at and :max_team_number, so once Task 3
  # delegates, every fixture in the suite goes through this path twice.
  it "returns the same run when asked twice" do
    game = create_game
    game.runs.delete_all
    game.reload

    expect(game.current_run).to equal(game.current_run)
  end

  it "builds only one run however many times it is asked" do
    game = create_game
    game.runs.delete_all
    game.reload

    3.times { game.current_run }
    game.save!

    expect(game.runs.reload.size).to eq(1)
  end

  it "returns the highest ordinal when several runs exist" do
    game = create_game
    game.runs.delete_all
    GameRun.create!(:game => game, :ordinal => 1)
    second = GameRun.create!(:game => game, :ordinal => 2)
    game.reload

    expect(game.current_run).to eq(second)
  end

  # has_many saves NEW children on parent save by default but does NOT save
  # CHANGED persisted ones -- which would break the edit form the moment Task 3
  # delegates. autosave: true is what makes `game.save` persist a modified run.
  it "saves a changed run when the game is saved" do
    game = create_game
    game.current_run.max_team_number = 77
    game.save!

    expect(game.runs.reload.last.max_team_number).to eq(77)
  end

  it "destroys its runs with the game" do
    game = create_game
    expect { game.destroy }.to change(GameRun, :count).by(-1)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/current_run_spec.rb
```

Expected: FAIL with `NoMethodError: undefined method 'runs'`.

- [ ] **Step 3: Add the association and the autobuild**

In `app/models/game.rb`, immediately after `has_many :levels` (around line 17):

```ruby
  # A Game is CONTENT; a GameRun is one running of it. The schedule lives on
  # the run from phase 1 onwards -- see
  # docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md.
  #
  # autosave: true is load-bearing, not decoration. has_many saves NEW children
  # on parent save but leaves CHANGED persisted ones alone, so without it
  # `game.starts_at = x; game.save` would silently not persist -- and that is
  # exactly the path the edit form and several frozen scenarios drive.
  #
  # inverse_of is required on both sides: the scope below and the name mismatch
  # (:runs -> GameRun) each independently defeat Rails' automatic inverse
  # detection, and GameRun validates the presence of its game.
  has_many :runs, -> { order(:ordinal) },
           :class_name => "GameRun", :inverse_of => :game,
           :autosave => true, :dependent => :destroy
```

And **now** add the other half of the inverse in `app/models/game_run.rb`, which Task 1 deliberately left off because Rails resolves a named inverse eagerly and raises `InverseOfAssociationNotFoundError` when the other side does not exist yet:

```ruby
  belongs_to :game, :optional => true, :inverse_of => :runs
```

And add `current_run` as a public method, next to the other predicates (after `editing_locked?`, around line 57):

```ruby
  # The run everything about the schedule reads and writes. Autobuilds rather
  # than returning nil because 70 places across spec/ and features/ construct
  # games as Game.new(:starts_at => ...) before any run could exist, and the
  # delegated writer has to land somewhere.
  #
  # runs.to_a.last, NOT runs.last, and the difference is a bug rather than a
  # style preference: runs.last on an unloaded association issues
  # SELECT ... ORDER BY ordinal DESC LIMIT 1 and cannot see a record that has
  # only been built in memory, so the second call would build a SECOND run and
  # autosave would persist both. to_a calls load_target, which merges unsaved
  # new records into the loaded target.
  #
  # "Current" is the highest ordinal, not "the one that is not finished" --
  # deterministic, and still correct in phase 3 when a second run exists.
  def current_run
    runs.to_a.last || runs.build(:ordinal => 1)
  end
```

- [ ] **Step 4: Run the new spec, then the whole suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/current_run_spec.rb
bundle exec rspec
```

Expected: the new file PASSes 6 examples; the full run has 0 failures. Nothing delegates yet, so the rest of the suite is untouched.

- [ ] **Step 5: Add the schedule helper**

In `spec/spec_helpers/fixtures_helper.rb`, at the end of the module:

```ruby
  # Arranges a game's SCHEDULE in a spec.
  #
  # Specs reach for update_column here because a running or finished game
  # cannot pass its own validations (game_starts_in_the_future fires whenever
  # author_finished_at is nil and starts_at is past), so an ordinary save would
  # raise on exactly the states these specs need to arrange.
  #
  # It writes BOTH the games column and the run for the duration of phase 1's
  # expand step, so this call site is correct both before and after the
  # delegation lands. The games write is deleted in the final task, once the run
  # is the only reader.
  #
  # Only the EIGHT MOVING COLUMNS belong here. withdrawn_at and
  # editing_locked_at stay on games -- keep using update_column for those.
  def set_game_schedule!(game, attrs)
    attrs.each { |column, value| game.update_column(column, value) }

    run = game.runs.first || game.runs.create!(:ordinal => 1)
    attrs.each { |column, value| run.update_column(column, value) }

    game
  end
```

- [ ] **Step 6: Route every moving-column arrangement through the helper**

Apply this transformation everywhere in `spec/`:

```
  game.update_column(:starts_at, X)          ->  set_game_schedule!(game, :starts_at => X)
  game.update_column(:author_finished_at, X) ->  set_game_schedule!(game, :author_finished_at => X)
  game.update_column(:requested_teams_number, X) -> set_game_schedule!(game, :requested_teams_number => X)
  game.update_column(:is_testing, X)         ->  set_game_schedule!(game, :is_testing => X)
```

Combine adjacent calls on the same game into one call — e.g. `spec/views/games_spec.rb:123-124` becomes
`set_game_schedule!(game, :starts_at => 2.hours.ago, :author_finished_at => 1.hour.ago)`.

**Leave `withdrawn_at` and `editing_locked_at` calls exactly as they are** (e.g. `spec/models/game/count_by_status_spec.rb:13`, `spec/models/game/status_spec.rb:41` via `withdraw!`).

The 20 files containing at least one call to change:

```
spec/models/game/status_spec.rb              spec/models/game/count_by_status_spec.rb
spec/models/game/place_of_spec.rb            spec/models/game_passing/interventions_spec.rb
spec/models/game_passing/check_answer_spec.rb  spec/models/game_passing/level_answered_spec.rb
spec/models/game_passing/correct_answer_spec.rb  spec/models/concerns/time_formatting_spec.rb
spec/models/team/deletable_spec.rb           spec/views/games_spec.rb
spec/views/game_passings_spec.rb             spec/assets/level_hint_updater_spec.rb
spec/requests/game_capacity_spec.rb          spec/requests/interventions_spec.rb
spec/requests/game_log_scope_spec.rb         spec/requests/code_deletion_spec.rb
spec/requests/game_registration_enforcement_spec.rb  spec/requests/play_screen_spec.rb
spec/requests/quiz_option_scope_spec.rb      spec/requests/withdrawal_spec.rb
spec/requests/timezone_preference_spec.rb    spec/requests/timezone_rendering_spec.rb
spec/requests/paused_hint_seeding_spec.rb    spec/requests/level_codes_rule_spec.rb
spec/requests/admin_game_authorship_spec.rb
```

Find every remaining one with:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "update_column" spec/ | grep -E "starts_at|author_finished_at|paused_at|is_testing|test_date|max_team_number|requested_teams_number|registration_deadline"
```

- [ ] **Step 7: Verify the transformation is complete and the suite is green**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "update_column" spec/ | grep -E "starts_at|author_finished_at|paused_at|is_testing|test_date|max_team_number|requested_teams_number|registration_deadline"
```

Expected: **no output**, except inside `fixtures_helper.rb` itself.

```bash
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec 0 failures. Cucumber **232 / 2342**.

- [ ] **Step 8: Commit**

```bash
git add app/models/game.rb spec/spec_helpers/fixtures_helper.rb spec/models/game/current_run_spec.rb spec/
git commit -m "Give Game its runs, and route spec schedules through a helper

current_run autobuilds because 70 places construct games with a
schedule before any run could exist. runs.to_a.last, not runs.last: the
latter queries and cannot see an in-memory built record, so a second
call would build a second run. autosave: true because has_many leaves
CHANGED children unsaved, which would break the edit form the moment
delegation lands.

The 59 spec arrangements move to set_game_schedule!, which writes both
the games column and the run -- correct on both sides of the delegation
switch, so the next commit does not have to touch 20 files."
```

---

### Task 3: Delegate, retarget the writers, and rewrite `count_by_status`

The switch. After this, the run is authoritative.

**Files:**
- Modify: `app/models/game.rb` — add the `delegate`, retarget `pause!`, `resume!`, `unfinish!`, `finish_game!`, `reserve_place_for_team!`, `free_place_of_team!`, rewrite `self.count_by_status`
- Test: `spec/models/game/schedule_delegation_spec.rb` (create)

**Interfaces:**
- Consumes: `Game#current_run` from Task 2.
- Produces: `Game#starts_at` and the other seven accessors read and write `current_run`. `Game.count_by_status` joins `game_runs`.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/game/schedule_delegation_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The schedule lives on the run; Game delegates. Phase 1's whole claim is that
# this changes nothing, so these examples check the paths the rest of the suite
# and the frozen scenarios actually drive.
RSpec.describe Game, "schedule delegation" do
  it "lands an attribute passed to new on the autobuilt run" do
    game = Game.new(:starts_at => Time.utc(2040, 1, 1, 12, 0))

    expect(game.current_run.starts_at).to eq(Time.utc(2040, 1, 1, 12, 0))
  end

  # create_game passes BOTH, which is what makes the runs.to_a.last hazard
  # reachable from every fixture in the suite.
  it "builds exactly one run for a game given several schedule attributes" do
    game = create_game(:starts_at => "2099-01-01 00:00", :max_team_number => 10)

    expect(game.runs.reload.size).to eq(1)
    expect(game.max_team_number).to eq(10)
  end

  it "persists a schedule change made through the game" do
    game = create_game
    game.max_team_number = 55
    game.save!

    expect(game.reload.max_team_number).to eq(55)
    expect(game.runs.reload.last.max_team_number).to eq(55)
  end

  it "reads back what the run holds" do
    game = create_game
    game.current_run.update_column(:starts_at, Time.utc(2045, 3, 3))

    expect(game.reload.starts_at).to eq(Time.utc(2045, 3, 3))
  end

  # D4: the four schedule validations stay on Game and read the delegated
  # values. If the delegation ever returns a stale games column, these pass
  # while validating the wrong number -- so they are asserted explicitly rather
  # than assumed from the suite staying green.
  describe "the validations that stayed on Game" do
    it "still rejects a start time in the past" do
      game = build_game(:starts_at => 1.hour.ago)

      expect(game).not_to be_valid
      expect(game.errors[:starts_at]).not_to be_empty
    end

    it "still rejects a registration deadline after the start" do
      game = build_game(:starts_at => "2099-01-01 00:00",
                        :registration_deadline => "2099-02-01 00:00")

      expect(game).not_to be_valid
      expect(game.errors[:registration_deadline]).not_to be_empty
    end

    it "still rejects a team cap below the number already registered" do
      game = create_game(:max_team_number => 5)
      set_game_schedule!(game, :requested_teams_number => 4)
      game.reload.max_team_number = 3

      expect(game).not_to be_valid
      expect(game.errors[:max_team_number]).not_to be_empty
    end

    # The error must still land on the FIELD, not on :base. Moving the
    # validations to GameRun and promoting them up would put them on :base --
    # which is exactly what D4 defers to phase 3 to avoid.
    it "puts the error on the field rather than on base" do
      game = build_game(:starts_at => 1.hour.ago)
      game.valid?

      expect(game.errors[:base]).to be_empty
    end
  end

  describe "the lifecycle writers" do
    # A started game fails its own validations, which is why these use
    # update_column. create_game defaults starts_at to 2099, so a spec that
    # does not arrange a started game proves nothing about the case these
    # methods exist for.
    def running_game
      game = create_game(:is_draft => false)
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      game
    end

    it "pauses onto the run" do
      game = running_game
      game.pause!

      expect(game.runs.reload.last.paused_at).to be_present
      expect(game.reload).to be_paused
    end

    it "resumes off the run" do
      game = running_game
      game.pause!
      game.resume!

      expect(game.runs.reload.last.paused_at).to be_nil
      expect(game.reload).not_to be_paused
    end

    it "finishes onto the run" do
      game = running_game
      game.finish_game!

      expect(game.runs.reload.last.author_finished_at).to be_present
      expect(game.reload).to be_author_finished
    end

    it "unfinishes off the run" do
      game = running_game
      game.finish_game!
      game.unfinish!

      expect(game.runs.reload.last.author_finished_at).to be_nil
      expect(game.reload).not_to be_author_finished
    end

    it "counts a reserved place onto the run" do
      game = create_game(:max_team_number => 5)
      game.reserve_place_for_team!

      expect(game.runs.reload.last.requested_teams_number).to eq(1)
      expect(game.reload.requested_teams_number).to eq(1)
    end

    it "frees a place off the run" do
      game = create_game(:max_team_number => 5)
      game.reserve_place_for_team!
      game.free_place_of_team!

      expect(game.runs.reload.last.requested_teams_number).to eq(0)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/schedule_delegation_spec.rb
```

Expected: FAIL — the first example fails because `Game.new(:starts_at => …)` writes the `games` column, leaving `current_run.starts_at` nil.

- [ ] **Step 3: Add the delegation**

In `app/models/game.rb`, immediately after the `has_many :runs` declaration added in Task 2:

```ruby
  # The eight scheduling columns now live on the run. These delegations are why
  # nothing else in the application had to change: Game#status, #started?,
  # #paused?, #author_finished?, every view and every controller keep reading
  # the same method names.
  #
  # The four schedule validations (game_starts_in_the_future,
  # deadline_is_in_future, deadline_is_before_game_start, valid_max_num)
  # deliberately stay on Game and read through these -- see the design, D4.
  delegate :starts_at, :starts_at=,
           :registration_deadline, :registration_deadline=,
           :max_team_number, :max_team_number=,
           :requested_teams_number, :requested_teams_number=,
           :author_finished_at, :author_finished_at=,
           :is_testing, :is_testing=,
           :test_date, :test_date=,
           :paused_at, :paused_at=,
           :to => :current_run
```

- [ ] **Step 4: Retarget the lifecycle writers**

In `app/models/game.rb`, change the `update_column` target in these four methods from the game to its run. `pause!` becomes:

```ruby
  def pause!
    raise ArgumentError, "already paused" if self.paused?

    current_run.update_column(:paused_at, Time.now)
  end
```

In `resume!`, only the last line changes — the `GamePassing` shift is untouched:

```ruby
      update_column(:paused_at, nil)      # before
      current_run.update_column(:paused_at, nil)   # after
```

`unfinish!` becomes:

```ruby
  def unfinish!
    current_run.update_column(:author_finished_at, nil)
  end
```

`finish_game!` keeps its shape — the delegated writer plus `autosave: true` persists the run:

```ruby
  def finish_game!
    self.author_finished_at = Time.now
    self.save!
  end
```

`reserve_place_for_team!` and `free_place_of_team!` also keep their shape, for the same reason: they read and write through the delegation and then `save`.

**`withdraw!`, `restore!`, `lock_editing!` and `unlock_editing!` are NOT changed** — their columns stay on `games`.

- [ ] **Step 5: Rewrite `count_by_status`**

Replace `self.count_by_status` in `app/models/game.rb`:

```ruby
  def self.count_by_status(now = Time.now)
    # LEFT JOIN, not an inner one: a game whose run is somehow missing must
    # still be counted, or the columns silently stop summing to the total --
    # which is the one thing a status table must never do. The MAX(ordinal)
    # condition picks the current run and is also what stops a game with two
    # runs being counted twice.
    joined = joins(<<~SQL)
      LEFT JOIN game_runs ON game_runs.game_id = games.id
        AND game_runs.ordinal = (SELECT MAX(r2.ordinal) FROM game_runs r2
                                  WHERE r2.game_id = games.id)
    SQL

    live       = joined.where(:withdrawn_at => nil)
    published  = live.where(:is_draft => false)
    unfinished = published.where("game_runs.author_finished_at IS NULL")

    {
      # Unjoined: withdrawn_at is still a games column, so this needs no run.
      :withdrawn => where.not(:withdrawn_at => nil).count,
      :draft     => live.where(:is_draft => true).count,
      :finished  => published.where("game_runs.author_finished_at IS NOT NULL").count,
      # starts_at is nullable and Game#started? treats NULL as not started, so
      # the NULL check is explicit rather than left to a comparison that would
      # evaluate to unknown and drop the row from every bucket.
      :running   => unfinished.where("game_runs.starts_at IS NOT NULL")
                              .where("game_runs.starts_at < ?", now).count,
      :scheduled => unfinished.where("game_runs.starts_at IS NULL OR game_runs.starts_at >= ?", now).count
    }
  end
```

- [ ] **Step 6: Run the targeted specs**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/schedule_delegation_spec.rb spec/models/game/status_spec.rb spec/models/game/count_by_status_spec.rb
```

Expected: PASS, 0 failures. `status_spec.rb`'s "agrees with count_by_status across every state" is the example that proves the SQL rewrite still matches the Ruby predicate — if only that one fails, the join is wrong, not the delegation.

- [ ] **Step 7: Run both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec 0 failures. Cucumber **232 scenarios (230 passed, 2 undefined), 2342 steps**. Cucumber is the gate that matters here — it drives the game create and edit forms, which is the path `autosave: true` exists for.

- [ ] **Step 8: Commit**

```bash
git add app/models/game.rb spec/models/game/schedule_delegation_spec.rb
git commit -m "Move the schedule onto the run; Game delegates

The eight scheduling accessors now read and write current_run, so
Game#status, every view and every controller keep working through the
same method names. pause!, resume! and unfinish! retarget their
update_column to the run; finish_game! and the capacity counters keep
their shape because the delegated writer plus autosave persists it.
withdraw!, restore! and the editing lock are untouched -- those columns
stay on games.

count_by_status is rewritten as a LEFT JOIN to the current run. Left,
not inner, so a game with no run still lands in a bucket rather than
making the columns stop summing."
```

---

### Task 4: Contract the test helper, proving the run is authoritative

The helper still writes the old `games` columns. Removing that write is the proof that nothing reads them any more — if a spec fails now, something is still reading `games.starts_at`.

**Files:**
- Modify: `spec/spec_helpers/fixtures_helper.rb`

**Interfaces:**
- Consumes: the delegation from Task 3.

- [ ] **Step 1: Delete the games-column write**

In `spec/spec_helpers/fixtures_helper.rb`, remove the first line of the method body and rewrite the comment:

```ruby
  # Arranges a game's SCHEDULE in a spec.
  #
  # Specs reach past validations here because a running or finished game cannot
  # pass its own (game_starts_in_the_future fires whenever author_finished_at is
  # nil and starts_at is past), so an ordinary save would raise on exactly the
  # states these specs need to arrange.
  #
  # Writes the RUN only. It briefly wrote the games columns too, so that the 59
  # call sites were correct on both sides of the delegation switch; that write
  # is gone, and the suite passing without it is the proof that nothing reads
  # those columns any more.
  #
  # Only the EIGHT MOVING COLUMNS belong here. withdrawn_at and
  # editing_locked_at stay on games -- keep using update_column for those.
  def set_game_schedule!(game, attrs)
    run = game.runs.first || game.runs.create!(:ordinal => 1)
    attrs.each { |column, value| run.update_column(column, value) }

    game
  end
```

- [ ] **Step 2: Run both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec 0 failures. Cucumber **232 / 2342**.

**A failure here is informative, not an obstacle.** It means a code path still reads the `games` column directly rather than through the delegation — find it, route it through `current_run`, and note it, because deploy 2 drops that column and the failure would otherwise appear in production.

- [ ] **Step 3: Confirm the application no longer names the moved columns on `games`**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "update_column\|update_columns" app/ | grep -E "starts_at|author_finished_at|paused_at|is_testing|test_date|max_team_number|requested_teams_number|registration_deadline"
```

Expected: only lines whose receiver is `current_run`. Any bare `update_column(:starts_at, …)` on a game is a write to a column that deploy 2 deletes.

- [ ] **Step 4: Boot the production environment**

Neither suite evaluates `config/environments/production.rb`, and this task changes the schema:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u SMTP_PASSWORD=p \
  SMTP_ADDRESS=s MAIL_FROM=m@e.com DATABASE_URL="sqlite3:/tmp/probe.sqlite3" \
  bin/rails runner 'puts "ok"'
bin/rails zeitwerk:check
```

Expected: `ok`, and `All is good!`.

- [ ] **Step 5: Commit**

```bash
git add spec/spec_helpers/fixtures_helper.rb
git commit -m "Stop writing the old games schedule columns from specs

The helper wrote both copies so its 59 call sites were correct on either
side of the delegation switch. Removing the games write is the proof
that nothing reads those columns any more -- which is what deploy 2
needs before it can drop them."
```

---

## Before deploying

**Rehearse the migration against a copy of production.** The fixtures cannot produce every lifecycle state that exists in the real database, and the backfill is the one irreversible-feeling step. Restore a copy per `docs/runbooks/restore.md`, run `db:migrate`, and check three things:

```sql
SELECT COUNT(*) FROM games;                                    -- N
SELECT COUNT(*) FROM game_runs;                                -- must also be N
SELECT COUNT(*) FROM games g LEFT JOIN game_runs r ON r.game_id = g.id
 WHERE r.id IS NULL;                                           -- must be 0
SELECT COUNT(*) FROM games g JOIN game_runs r ON r.game_id = g.id
 WHERE g.starts_at IS DISTINCT FROM r.starts_at;               -- must be 0
SELECT COUNT(*) FROM game_passings WHERE game_id IS NOT NULL AND game_run_id IS NULL;  -- must be 0
```

The fourth query is the one that catches the nil-copying disaster the migration's comment warns about. On SQLite use `IS NOT` in place of `IS DISTINCT FROM`.

**Rollback after deploy 1** is `kamal rollback` — the `games` columns are still present and populated, so no database restore is needed. It is lossless **until an author edits a schedule**, after which that edit lives only in `game_runs` and reverting loses it. Nothing is corrupted and no player history is affected.

**Deploy 2 — dropping the eight `games` columns — is deliberately not in this plan.** It is a separate one-migration change, made after this has been seen working in production, and it is the point of no return: after it, the old code no longer boots.
