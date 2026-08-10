# Game Runs, Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make results, logs and stats read through `game_run_id` instead of `game_id`, changing nothing a user can see.

**Architecture:** Logs gain a `game_run_id` of their own (backfilled), the run-aware read methods move from `Game` onto `GameRun` with `Game` delegating to `current_run`, and every remaining `of_game` query on the results/log/stats paths becomes run-scoped. Because every production game has exactly one run, all of this is invisible — which is also why the **isolation specs, which build a second run themselves, are the real deliverable**.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec, sqlite in dev/test, PostgreSQL in production. Migrations run under `bin/docker-entrypoint`'s `db:prepare` before puma starts.

**Spec:** `docs/superpowers/specs/2026-08-10-game-runs-phase-2-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix every command with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any file under `features/`.** This plan touches none.
- **Cucumber must stay at exactly 232 scenarios (230 passed, 2 undefined) / 2342 steps** after every task. The frozen scenarios drive the results table, the live channel and the log screens, so this is a real gate here.
- **No locale key is added or changed, and no view gains or loses text.** If a task seems to need one, stop — the design is wrong, not the code.
- **A green suite does not prove scoping.** With one run per game every scoped query returns what the unscoped one returned. Any task that scopes something must add an example that builds a **second** `GameRun` and asserts isolation.
- **Do not touch `GameEntry` scoping.** It carries a backfilled `game_run_id` from phase 1 that stays unread until phase 3.
- **`Game#deletable?` stays game-scoped.** It must refuse deletion while *any* run's history exists.
- **Hash-rocket style** (`:key => value`), comments in English, user-facing strings in Russian.
- Run `bin/rails db:test:prepare` after the migration task. Commit after every task.

---

### Task 1: Logs get a run of their own

Adds the column, the backfill, the scope and the write. **Nothing reads it yet**, so the suite must be untouched. Also moves every spec that creates a log onto a fixture helper, so Task 3 does not have to touch 23 call sites while flipping behaviour.

**Files:**
- Create: `db/migrate/20260810160000_add_game_run_id_to_logs.rb`
- Modify: `app/models/log.rb`
- Modify: `app/controllers/game_passings_controller.rb:356-364` (`save_log`)
- Modify: `spec/spec_helpers/fixtures_helper.rb`
- Modify: `spec/models/log_spec.rb`, `spec/requests/log_backfill_spec.rb`, `spec/requests/game_log_scope_spec.rb`, `spec/requests/full_log_scope_spec.rb`, `spec/views/logs_spec.rb`, `spec/models/team/deletable_spec.rb`
- Test: `spec/models/log/run_backfill_spec.rb` (create)
- Modify: `db/schema.rb` (regenerated)

**Interfaces:**
- Produces: `logs.game_run_id`; `Log.of_run(run)`; `Log.backfill_run_ids!` → `{ :resolved => Integer }`; `create_log(attrs)` in `FixturesHelper`. Task 3 consumes `Log.of_run`.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/log/run_backfill_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# A log states its run as a fact rather than inferring it from the team's
# passing. The inference is unambiguous only while a game has one run, and
# phase 3 is exactly when it stops being.
RSpec.describe Log, ".backfill_run_ids!" do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  def bare_log
    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "код")
  end

  it "resolves a log to its game's run" do
    log = bare_log
    log.update_column(:game_run_id, nil)

    expect { Log.backfill_run_ids! }
      .to change { log.reload.game_run_id }.from(nil).to(game.current_run.id)
  end

  it "reports how many it resolved" do
    log = bare_log
    log.update_column(:game_run_id, nil)

    expect(Log.backfill_run_ids!).to eq(:resolved => 1)
  end

  # Idempotent: a silent backfill that resolved nothing must not look
  # identical to one that resolved everything -- the reason backfill_ids!
  # returns counts too.
  it "resolves nothing on a second run and says so" do
    bare_log
    Log.backfill_run_ids!

    expect(Log.backfill_run_ids!).to eq(:resolved => 0)
  end

  it "leaves a log with no game alone" do
    orphan = Log.create!(:game_id => nil, :level => "x", :team => "y",
                         :time => Time.now, :answer => "z")
    orphan.update_column(:game_run_id, nil)

    Log.backfill_run_ids!

    expect(orphan.reload.game_run_id).to be_nil
  end

  # run_one is captured BEFORE the second run is created: create_next_run gives
  # the game a higher ordinal, so current_run then answers with the new run.
  it "scopes logs to a run" do
    run_one = game.current_run
    mine = Log.create!(:game_id => game.id, :game_run_id => run_one.id,
                       :level => level.name, :level_id => level.id,
                       :team => team.name, :team_id => team.id,
                       :time => Time.now, :answer => "мой")
    other_run = create_next_run(game)
    Log.create!(:game_id => game.id, :game_run_id => other_run.id,
                :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "другой")

    expect(Log.of_run(run_one).map(&:id)).to eq([ mine.id ])
    expect(Log.of_run(other_run).map(&:answer)).to eq([ "другой" ])
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/log/run_backfill_spec.rb
```

Expected: FAIL — `create_next_run` and `Log.backfill_run_ids!` do not exist, and `game_run_id` is not a column.

- [ ] **Step 3: Add the second-run fixture helper**

`create_next_run` is used by every isolation spec in this plan. In `spec/spec_helpers/fixtures_helper.rb`, at the end of the module:

```ruby
  # A SECOND run on a game. Nothing in the application can create one until
  # phase 3, and every isolation example in phase 2 needs one: with a single
  # run every run-scoped query returns exactly what the game-scoped one
  # returned, so an example without this would pass whether the scoping worked
  # or not.
  def create_next_run(game, attrs = {})
    GameRun.create!({ :game => game,
                      :ordinal => game.runs.reload.maximum(:ordinal).to_i + 1,
                      :starts_at => game.starts_at,
                      :max_team_number => game.max_team_number }.merge(attrs))
  end

  # A log row, with its run filled in from the game. Specs wrote Log.create!
  # by hand in 23 places; routing them through here is what let phase 2 add
  # game_run_id without editing all of them again when the log screens became
  # run-scoped.
  def create_log(attrs = {})
    game  = attrs[:game]  || create_game
    level = attrs[:level] || create_level(:game => game)
    team  = attrs[:team]  || create_team(:captain => create_user)

    Log.create!(:game_id     => game.id,
                :game_run_id => (attrs[:game_run] || game.current_run).id,
                :level       => attrs[:level_name] || level.name,
                :level_id    => attrs.key?(:level_id) ? attrs[:level_id] : level.id,
                :team        => attrs[:team_name] || team.name,
                :team_id     => attrs.key?(:team_id) ? attrs[:team_id] : team.id,
                :time        => attrs[:time] || Time.now,
                :answer      => attrs[:answer] || "код")
  end
```

- [ ] **Step 4: Write the migration**

Create `db/migrate/20260810160000_add_game_run_id_to_logs.rb`:

```ruby
# Phase 2: a log states which RUNNING of a game it belongs to.
#
# Deriving it instead -- team + game -> passing -> run -- is unambiguous only
# while a game has one run. Phase 3 lets a team hold a passing in two runs of
# one game, and the join then breaks exactly where it matters: an author
# watching run 2's live channel would see run 1's answers.
class AddGameRunIdToLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :logs, :game_run_id, :integer
    add_index  :logs, :game_run_id

    # Through the model, unlike phase 1's backfill. That one had to avoid Game
    # because Game#starts_at delegates to an autobuilt run and would have read
    # nil; nothing of the sort applies here -- Log has no delegation, and
    # reporting counts is worth more than shaving a query.
    counts = Log.backfill_run_ids!
    say "backfilled game_run_id on #{counts[:resolved]} log row(s)"
  end

  def down
    remove_column :logs, :game_run_id
  end
end
```

- [ ] **Step 5: Add the scope and the backfill**

In `app/models/log.rb`, after the `of_level` scope:

```ruby
  scope :of_run, ->(run) { where(:game_run_id => run.id) }

  # Idempotent and safe to re-run: only touches rows whose game_run_id is
  # still NULL. Returns the count, which the migration logs -- a backfill that
  # resolved nothing would otherwise look identical to one that resolved
  # everything, which is why backfill_ids! above reports too.
  #
  # Resolves from game_id ALONE, because today every log of a game belongs to
  # that game's only run. That is exactly correct now and would be ambiguous
  # once a second run exists -- which is the whole reason this column is being
  # stored rather than the join being written into the log views.
  def self.backfill_run_ids!
    resolved = 0

    where(:game_run_id => nil).where.not(:game_id => nil).find_each do |log|
      run = GameRun.where(:game_id => log.game_id).order(:ordinal).last
      next if run.nil?

      log.update_column(:game_run_id, run.id)
      resolved += 1
    end

    { :resolved => resolved }
  end
```

- [ ] **Step 6: Write the run on every new log**

In `app/controllers/game_passings_controller.rb`, `save_log`:

```ruby
  def save_log
    return unless @game_passing.current_level&.id

    level = Level.find(@game_passing.current_level.id)
    # From the PASSING, not from @game.current_run: the passing is what this
    # answer actually belongs to, and in phase 3 a team's passing may be in a
    # run that is no longer the current one.
    Log.create!(game_id: @game.id, game_run_id: @game_passing.game_run_id,
                level: level.name, level_id: level.id,
                team: @team.name,  team_id: @team.id,
                time: Time.now, answer: @answer)
  end
```

- [ ] **Step 7: Migrate and run the new spec**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
bundle exec rspec spec/models/log/run_backfill_spec.rb
```

Expected: PASS, 5 examples, 0 failures. Commit the regenerated `db/schema.rb`; do not hand-edit it.

- [ ] **Step 8: Route the hand-written log creations through the helper**

Replace every `Log.create!(...)` in `spec/` with `create_log(...)`. Find them with:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "Log.create!" spec/
```

The mapping, for a call like
`Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id, :team => team.name, :team_id => team.id, :time => Time.now, :answer => "код")`:

```ruby
create_log(:game => game, :level => level, :team => team, :answer => "код")
```

Keep the explicit forms where an example deliberately writes an odd row:

- a **name that matches no record** — `create_log(:game => game, :level_name => "Старое задание", :level_id => nil, ...)`
- a **deliberately wrong `game_id`** (`spec/requests/game_log_scope_spec.rb:47` passes `:game_id => level.id`) — leave that one as a bare `Log.create!` and add `:game_run_id => game.current_run.id`, because the whole point of the row is that its `game_id` is wrong.
- `spec/models/log_spec.rb` and `spec/requests/log_backfill_spec.rb` exercise `backfill_ids!`, which needs rows whose `team_id`/`level_id` are NULL — pass `:team_id => nil` / `:level_id => nil` explicitly.

- [ ] **Step 9: Run both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec 0 failures. Cucumber **232 scenarios (230 passed, 2 undefined), 2342 steps**. Nothing reads `game_run_id` on logs yet, so any change is a real regression.

- [ ] **Step 10: Commit**

```bash
git add db/migrate app/models/log.rb app/controllers/game_passings_controller.rb spec/ db/schema.rb
git commit -m "Give a log its own run

Derived from game_id today, because a game has one run -- which is
exactly the assumption phase 3 breaks, and the reason this is stored
rather than joined at read time. save_log takes the run from the
passing, not from the game's current run: the passing is what the
answer belongs to.

Spec log creation moves to a create_log helper so that scoping the log
screens does not mean editing 23 call sites again."
```

---

### Task 2: The read methods move to `GameRun`

**Files:**
- Modify: `app/models/game_run.rb`
- Modify: `app/models/game_passing.rb` (add `belongs_to :game_run`; remove `self.of`)
- Modify: `app/models/game.rb` (`place_of`, `finished_teams` become delegations)
- Modify: `app/models/team.rb:25-33`
- Modify: `app/helpers/game_passings_helper.rb:47`
- Modify: `app/controllers/logs_controller.rb:98`
- Modify: `app/controllers/game_passings_controller.rb:315-325`
- Modify: `spec/spec_helpers/fixtures_helper.rb` (`create_game_passing` defaults the run)
- Test: `spec/models/game_run/results_spec.rb` (create)

**Interfaces:**
- Consumes: `create_next_run(game)` from Task 1.
- Produces: `GameRun#passings`, `GameRun#passing_for(team)` → `GamePassing` or nil, `GameRun#finished_teams` → `[Team]`, `GameRun#place_of(team)` → `Integer` or nil. `Game#place_of` / `#finished_teams` delegate. `GamePassing.of` **no longer exists**. Task 3 consumes `run.passings`.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/game_run/results_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Results belong to a RUN, not to a game. Every example here builds a second
# run, because with one run a run-scoped query returns exactly what the
# game-scoped one returned and would pass either way.
RSpec.describe GameRun, "results" do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }

  def finished_passing(run, team, finished_at, penalty = 0)
    passing = create_game_passing(:level => level, :team => team, :game_run => run)
    passing.update_column(:finished_at, finished_at)
    passing.update_column(:penalty_seconds, penalty)
    passing
  end

  it "lists only its own passings" do
    run_one = game.current_run
    run_two = create_next_run(game)
    mine = create_game_passing(:level => level, :game_run => run_one)
    create_game_passing(:level => level, :game_run => run_two)

    expect(run_one.passings.map(&:id)).to eq([ mine.id ])
  end

  it "finds a team's passing within itself only" do
    run_one = game.current_run
    run_two = create_next_run(game)
    team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => team, :game_run => run_two)

    expect(run_one.passing_for(team)).to be_nil
    expect(run_two.passing_for(team)).to be_present
  end

  it "counts only its own finished teams" do
    run_one = game.current_run
    run_two = create_next_run(game)
    mine = create_team(:captain => create_user)
    theirs = create_team(:captain => create_user)
    finished_passing(run_one, mine, 1.hour.ago)
    finished_passing(run_two, theirs, 1.hour.ago)

    expect(run_one.finished_teams).to eq([ mine ])
  end

  it "ranks within its own run" do
    run = game.current_run
    first = create_team(:captain => create_user)
    second = create_team(:captain => create_user)
    finished_passing(run, first, 3.hours.ago)
    finished_passing(run, second, 1.hour.ago)

    expect(run.place_of(first)).to eq(1)
    expect(run.place_of(second)).to eq(2)
  end

  # THE example this whole programme exists for. A team that finished earlier
  # in absolute wall-clock time in an EARLIER run must not take a place from a
  # later run's ranking -- which is precisely what game-scoped, absolute-time
  # ranking did.
  it "is not affected by a team that finished earlier in another run" do
    run_one = game.current_run
    run_two = create_next_run(game)
    old_timer = create_team(:captain => create_user)
    newcomer  = create_team(:captain => create_user)
    finished_passing(run_one, old_timer, 30.days.ago)
    finished_passing(run_two, newcomer, 1.hour.ago)

    expect(run_two.place_of(newcomer)).to eq(1)
  end

  it "returns nil for a team that has not finished" do
    run = game.current_run
    team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => team, :game_run => run)

    expect(run.place_of(team)).to be_nil
  end

  # Penalties still count, and still within the run.
  it "ranks a penalised early finisher behind a clean later one" do
    run = game.current_run
    guesser = create_team(:captain => create_user)
    steady  = create_team(:captain => create_user)
    finished_passing(run, guesser, 2.hours.ago, 7200)
    finished_passing(run, steady, 90.minutes.ago, 0)

    expect(run.place_of(steady)).to eq(1)
  end

  describe "Game's delegations" do
    it "answers place_of from the current run" do
      run = game.current_run
      team = create_team(:captain => create_user)
      finished_passing(run, team, 1.hour.ago)

      expect(game.place_of(team)).to eq(run.place_of(team))
    end

    it "answers finished_teams from the current run" do
      run = game.current_run
      team = create_team(:captain => create_user)
      finished_passing(run, team, 1.hour.ago)

      expect(game.finished_teams).to eq(run.finished_teams)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game_run/results_spec.rb
```

Expected: FAIL — `GameRun#passings` does not exist and `create_game_passing` does not accept `:game_run`.

- [ ] **Step 3: Associate a passing with its run**

In `app/models/game_passing.rb`, beside the other `belongs_to`s:

```ruby
  belongs_to :game_run, :optional => true
```

And **delete** `self.of` (lines 81-83) — `run.passing_for(team)` replaces it. Leaving both would be two ways to ask one question, which is how the stale one survives.

- [ ] **Step 4: Add the read methods to `GameRun`**

In `app/models/game_run.rb`, after the validations:

```ruby
  has_many :passings, :class_name => "GamePassing", :foreign_key => "game_run_id"

  # Replaces GamePassing.of(team, game). A team has at most one passing per
  # run; in phase 3 it may have one in each of several runs of the same game,
  # which is exactly what the old game-scoped lookup could not express.
  def passing_for(team)
    passings.of_team(team).first
  end

  def finished_teams
    passings.finished.map(&:team)
  end

  # Ranks on finish time PLUS accrued penalty, so a team that guessed its way
  # to an early finish places behind one that took longer and did not.
  #
  # Compared in Ruby rather than SQL: expressing "finished_at + penalty_seconds"
  # as a portable interval across SQLite and PostgreSQL is more trouble than it
  # is worth for a listing of tens of teams.
  #
  # Scoped to THIS run. Game-scoped ranking compared absolute timestamps across
  # every cohort that ever played, so a team playing months later always placed
  # last however fast it was -- the defect this whole programme exists to fix.
  def place_of(team)
    passing = passing_for(team)
    return nil unless passing and passing.finished?

    mine = passing.effective_finished_at
    earlier = passings.finished.count do |other|
      other.effective_finished_at < mine
    end
    earlier + 1
  end
```

- [ ] **Step 5: Turn `Game`'s versions into delegations**

Replace `Game#finished_teams` and `Game#place_of` (and their comments, which move to `GameRun`) with:

```ruby
  # Results belong to a run. These answer for the CURRENT one, which is what
  # every caller reached by a game-id URL means; phase 3 introduces the screens
  # that name a run explicitly.
  def finished_teams
    current_run.finished_teams
  end

  def place_of(team)
    current_run.place_of(team)
  end
```

- [ ] **Step 6: Replace the five `GamePassing.of` call sites**

`app/models/team.rb` — both keep taking a **game**, because the screens that ask know a game, not a run:

```ruby
  def current_level_in(game)
    game_passing = game.current_run.passing_for(self)
    game_passing.try :current_level
  end

  def finished?(game)
    game_passing = game.current_run.passing_for(self)
    !! game_passing.try(:finished?)
  end
```

`app/helpers/game_passings_helper.rb:47`:

```ruby
    game_passing = current_user.team && game.current_run.passing_for(current_user.team)
```

`app/controllers/logs_controller.rb:98`:

```ruby
    game_passing = current_user.team && @game.current_run.passing_for(current_user.team)
```

`app/controllers/game_passings_controller.rb#find_or_create_game_passing`:

```ruby
  def find_or_create_game_passing
    @game_passing = @game.current_run.passing_for(@team)
    return @game_passing if @game_passing

    unless may_start_passing?
      raise Authentication::Unauthorized, t("errors.not_registered_for_game")
    end

    @game_passing = GamePassing.create!(team: @team, game: @game,
                                        game_run: @game.current_run,
                                        current_level: @game.levels.first)
  end
```

- [ ] **Step 7: Default the run in the passing fixture**

`create_game_passing` is used in 85 places. Without a run they would all be invisible to run-scoped queries in Task 3. In `spec/spec_helpers/fixtures_helper.rb`:

```ruby
  def create_game_passing(options={})
    current_level = options.delete(:level) || create_level
    game = current_level.game

    creation_params = {
      :game => game,
      # Every passing belongs to a run. Defaulted here rather than at 85 call
      # sites; pass :game_run explicitly to place one in a different run, which
      # is what the isolation examples do.
      :game_run => game.current_run,
      :current_level => current_level,
      :team => create_team
    }.merge(options)

    GamePassing.create! creation_params
  end
```

- [ ] **Step 8: Run the new spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game_run/results_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file PASSes 9 examples; RSpec 0 failures; Cucumber **232 / 2342**.

If a spec that calls `GamePassing.create!` **directly** (rather than through the fixture) now fails, give it `:game_run => game.current_run`. Find them with `grep -rn "GamePassing.create" spec/`.

- [ ] **Step 9: Commit**

```bash
git add app/models spec/ app/helpers app/controllers
git commit -m "Move results onto the run

place_of, finished_teams and the passing lookup become GameRun methods;
Game keeps one-line delegations to current_run so callers reached by a
game-id URL are untouched. GamePassing.of is removed rather than kept
alongside run.passing_for -- two ways to ask one question is how the
stale one survives.

The examples build a second run, because with one run a run-scoped
query returns exactly what the game-scoped one did. One pins the defect
the programme exists for: a team finishing earlier in absolute time in
an earlier run must not take a place from a later run's ranking."
```

---

### Task 3: The screens and the remaining `of_game` queries

**Files:**
- Modify: `app/views/game_passings/show_results.html.erb:17`
- Modify: `app/controllers/game_passings_controller.rb:65`
- Modify: `app/controllers/logs_controller.rb:32,47,51,55`
- Modify: `app/controllers/interventions_controller.rb:84`
- Modify: `app/models/game.rb` (`resume!`)
- Modify: `app/controllers/games_controller.rb:90` (`end_game`), `:216-217` (`finish_test`)
- Test: `spec/requests/run_scoped_screens_spec.rb` (create)

**Interfaces:**
- Consumes: `GameRun#passings` and `Log.of_run(run)`.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/run_scoped_screens_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Every screen that shows results or logs must show ONE run's. All of these
# build a second run: with a single run each of these queries returns what the
# game-scoped version returned, so an example without one proves nothing.
describe "screens scoped to a run", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author, :is_draft => false); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let(:level)  { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A team whose passing and log live in a run that is NOT the current one.
  def team_in_old_run
    old_run = game.current_run
    team = create_team(:captain => create_user, :name => "Прошлый забег")
    passing = create_game_passing(:level => level, :team => team, :game_run => old_run)
    passing.update_column(:finished_at, 2.days.ago)
    create_log(:game => game, :level => level, :team => team,
               :game_run => old_run, :answer => "старыйкод")
    team
  end

  # Promote a NEW run to current, leaving the old one behind with its history.
  def open_second_run
    create_next_run(game)
    game.reload
  end

  it "shows only the current run's teams in the results table" do
    old = team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user, :name => "Текущий забег")
    p = create_game_passing(:level => level, :team => current_team, :game_run => game.current_run)
    p.update_column(:finished_at, 1.hour.ago)

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).to include("Текущий забег")
    expect(response.body).not_to include(old.name)
  end

  it "shows only the current run's answers in the live channel" do
    team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user)
    create_log(:game => game, :level => level, :team => current_team,
               :game_run => game.current_run, :answer => "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id)

    expect(response.body).to include("новыйкод")
    expect(response.body).not_to include("старыйкод")
  end

  it "shows only the current run's answers in the full log" do
    team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user)
    create_log(:game => game, :level => level, :team => current_team,
               :game_run => game.current_run, :answer => "новыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include("новыйкод")
    expect(response.body).not_to include("старыйкод")
  end

  it "lists only the current run's passings for the author" do
    old = team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user, :name => "Текущий забег")
    create_game_passing(:level => level, :team => current_team, :game_run => game.current_run)
    sign_in(author)

    get game_stats_path(:game_id => game.id)

    expect(response.body).to include("Текущий забег")
    expect(response.body).not_to include(old.name)
  end

  # finish_test DELETES player history, which is why it is scoped rather than
  # left game-wide: in phase 3 a test run must not erase a real run's results.
  #
  # Its own game, deliberately not the started `game` above: finish_test calls
  # @game.save, and game_starts_in_the_future refuses any game whose starts_at
  # is past while author_finished_at is nil -- so on a started game the save
  # fails, the action redirects with an alert, and nothing is deleted. The
  # example would then pass without ever exercising the deletion.
  it "deletes only the current run's passings and logs when a test is finished" do
    tested = create_game(:author => author, :is_draft => true)
    tested_level = create_level(:game => tested)
    old_run = tested.current_run
    old_team = create_team(:captain => create_user)
    create_game_passing(:level => tested_level, :team => old_team, :game_run => old_run)
    create_log(:game => tested, :level => tested_level, :team => old_team,
               :game_run => old_run, :answer => "старыйкод")

    create_next_run(tested)
    tested.reload
    new_team = create_team(:captain => create_user)
    create_game_passing(:level => tested_level, :team => new_team, :game_run => tested.current_run)
    create_log(:game => tested, :level => tested_level, :team => new_team,
               :game_run => tested.current_run, :answer => "новыйкод")

    sign_in(author)
    post finish_test_game_path(tested)

    expect(GamePassing.where(:game_run_id => old_run.id).count).to eq(1)
    expect(Log.where(:game_run_id => old_run.id).count).to eq(1)
    expect(GamePassing.where(:game_run_id => tested.reload.current_run.id).count).to eq(0)
    expect(Log.where(:game_run_id => tested.current_run.id).count).to eq(0)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/run_scoped_screens_spec.rb
```

Expected: FAIL — each screen still renders the old run's team or answer.

- [ ] **Step 3: Scope the results table and the passings list**

`app/views/game_passings/show_results.html.erb:17`:

```erb
<% game_passings = @game.current_run.passings %>
```

`app/controllers/game_passings_controller.rb:65`:

```ruby
    @game_passings = @game.current_run.passings
```

- [ ] **Step 4: Scope the four log screens**

In `app/controllers/logs_controller.rb`, replace `Log.of_game(@game)` with `Log.of_run(@game.current_run)` in all four actions:

```ruby
  def show_live_channel
    @logs = Log.of_run(@game.current_run).includes(:team_record, :level_record)
  end
```

```ruby
    @logs = @level ? Log.of_run(@game.current_run).of_team(@team).of_level(@level) : Log.none
```

```ruby
  def show_game_log
    @logs = Log.of_run(@game.current_run).of_team(@team)
  end
```

```ruby
  def show_full_log
    @logs = Log.of_run(@game.current_run)
```

`@levels = Level.of_game(@game)` on the next line is **unchanged** — levels belong to the game's content, not to a run.

- [ ] **Step 5: Scope the intervention lookup, resume, end and finish_test**

`app/controllers/interventions_controller.rb:84`:

```ruby
    @game_passing = @game.current_run.passings.of_team(params[:team_id]).first
```

`app/models/game.rb`, inside `resume!` — only the current run has running clocks:

```ruby
      current_run.passings.where(:finished_at => nil).find_each do |gp|
```

`app/controllers/games_controller.rb:90`:

```ruby
    @game.current_run.passings.each(&:end!)
```

`app/controllers/games_controller.rb:216-217` — this one deletes player history, so in phase 3 a test run must not erase a real run's results:

```ruby
    @game.current_run.passings.delete_all
    Log.of_run(@game.current_run).delete_all
```

- [ ] **Step 6: Run the new spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/run_scoped_screens_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file PASSes 5 examples; RSpec 0 failures; Cucumber **232 / 2342**. Cucumber is the gate that matters here — the frozen scenarios drive the results table, the live channel and both log screens.

- [ ] **Step 7: Confirm no results or log query is still game-scoped**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "of_game" app/ --include=*.rb --include=*.erb
```

Expected hits only: `Level.of_game` (levels are content), `GameEntry.of_game` (phase 3), and the scope definitions themselves. **No `GamePassing.of_game` or `Log.of_game` call should remain.**

- [ ] **Step 8: Commit**

```bash
git add app/ spec/
git commit -m "Scope the results, log and stats screens to the run

Every one of these is reached by a URL carrying a game id and no run
id, so each resolves current_run; phase 3 introduces the screens that
name a run. finish_test is scoped for a sharper reason than the rest --
it deletes player history, and a test run must not erase a real run's
results.

Level.of_game is deliberately untouched: levels are the game's content,
not a run's."
```

---

### Task 4: One passing per team per run, enforced

**Files:**
- Create: `db/migrate/20260810170000_add_unique_index_to_game_passings_on_team_and_run.rb`
- Test: `spec/models/game_passing/unique_per_run_spec.rb` (create)
- Modify: `db/schema.rb` (regenerated)

**Interfaces:**
- Consumes: `game_passings.game_run_id` (phase 1) and the run-scoped write from Task 2.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/game_passing/unique_per_run_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# One passing per team per run. Until this index existed the invariant was
# enforced only by find_or_create_game_passing's read, so a double-submitted
# first request could create two.
RSpec.describe GamePassing, "one per team per run" do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  it "refuses a second passing for the same team in the same run" do
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)

    expect {
      GamePassing.create!(:game => game, :game_run => game.current_run,
                          :team => team, :current_level => level)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # The same team playing a LATER run is the whole point of the programme, so
  # the index must not stand in its way.
  it "allows the same team a passing in a different run" do
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)
    second = create_next_run(game)

    expect {
      GamePassing.create!(:game => game, :game_run => second,
                          :team => team, :current_level => level)
    }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game_passing/unique_per_run_spec.rb
```

Expected: the first example FAILs — no error is raised, because nothing enforces the invariant.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260810170000_add_unique_index_to_game_passings_on_team_and_run.rb`:

```ruby
# One passing per team per run. Until now the invariant was enforced only by
# GamePassingsController#find_or_create_game_passing's read, so two
# near-simultaneous first requests could each miss and create one.
class AddUniqueIndexToGamePassingsOnTeamAndRun < ActiveRecord::Migration[8.0]
  def up
    # Check first rather than letting add_index raise. Migrations run under
    # bin/docker-entrypoint's db:prepare BEFORE puma starts, so an index that
    # raises on unexpected data takes the whole app down mid-deploy with an
    # opaque uniqueness error, recoverable only by someone shelling in to clean
    # the table by hand. Saying so and completing keeps the app up; the index
    # is simply absent until someone resolves the duplicates and re-runs this.
    #
    # Production had 3 game_passings when this was written, so it will not
    # fire there -- the guard is for restored or future data.
    duplicates = GamePassing.where.not(:game_run_id => nil)
                            .group(:team_id, :game_run_id)
                            .having("COUNT(*) > 1")
                            .count

    if duplicates.any?
      say "SKIPPED: #{duplicates.size} (team_id, game_run_id) pair(s) have more than one " \
          "game_passings row -- unique index NOT added. Resolve the duplicates and re-run " \
          "this migration. Pairs: #{duplicates.keys.inspect}"
    else
      add_index :game_passings, [ :team_id, :game_run_id ],
                unique: true,
                name: "index_game_passings_on_team_id_and_game_run_id"
      say "added unique index on game_passings (team_id, game_run_id)"
    end
  end

  def down
    remove_index :game_passings,
                 name: "index_game_passings_on_team_id_and_game_run_id",
                 if_exists: true
  end
end
```

- [ ] **Step 4: Migrate and run the spec**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
bundle exec rspec spec/models/game_passing/unique_per_run_spec.rb
```

Expected: PASS, 2 examples, 0 failures.

- [ ] **Step 5: Prove the duplicate guard actually guards**

A guard that has only ever run against clean data is untested. Run the check's own query against a table that **does** contain duplicates, and confirm it finds them rather than the migration having been a no-op:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails runner -e test 'g = Game.create!(:author => User.create!(:nickname => "dup1", :email => "dup1@e.invalid", :password => "1234", :password_confirmation => "1234"), :name => "dupgame", :description => "d", :starts_at => "2099-01-01 00:00", :max_team_number => 5); t = Team.create!(:name => "dupteam"); l = Level.create!(:game => g, :name => "L", :text => "t", :correct_answer => "c"); r = g.current_run; 2.times { GamePassing.new(:game => g, :game_run => r, :team => t, :current_level => l).save!(:validate => false) rescue nil }; dups = GamePassing.where.not(:game_run_id => nil).group(:team_id, :game_run_id).having("COUNT(*) > 1").count; puts "duplicate pairs found: #{dups.size}"; GamePassing.delete_all; Log.delete_all; Level.delete_all; Game.delete_all; Team.delete_all; User.delete_all'
```

That version only proves the **index** refuses duplicates. To prove the **guard** — the duplicate check that decides whether the index is added at all — the index has to be absent and duplicates present. Do it inside a transaction that rolls back, so the database is left exactly as it was:

```ruby
# tmp/guard_probe.rb, run with: RAILS_ENV=test bin/rails runner tmp/guard_probe.rb
INDEX = "index_game_passings_on_team_id_and_game_run_id".freeze

def duplicate_pairs
  GamePassing.where.not(:game_run_id => nil)
             .group(:team_id, :game_run_id).having("COUNT(*) > 1").count
end

conn = ActiveRecord::Base.connection

ActiveRecord::Base.transaction do
  conn.remove_index :game_passings, :name => INDEX

  user  = User.create!(:nickname => "guard#{rand(99999)}", :email => "guard#{rand(99999)}@e.invalid",
                       :password => "1234", :password_confirmation => "1234")
  game  = Game.create!(:author => user, :name => "guard#{rand(99999)}", :description => "d",
                       :starts_at => "2099-01-01 00:00", :max_team_number => 5)
  level = Level.create!(:game => game, :name => "L", :text => "t", :correct_answer => "c")
  team  = Team.create!(:name => "guardteam#{rand(99999)}")

  2.times { GamePassing.create!(:game => game, :game_run => game.current_run,
                                :team => team, :current_level => level) }

  puts "duplicate pairs the guard sees: #{duplicate_pairs.size}"
  puts "guard would SKIP the index: #{duplicate_pairs.any?}"
  raise ActiveRecord::Rollback
end

puts "leftover rows -- passings=#{GamePassing.count} games=#{Game.count}"
```

Expected: `duplicate pairs the guard sees: 1`, `guard would SKIP the index: true`, and `leftover rows -- passings=0 games=0`. Delete `tmp/guard_probe.rb` afterwards.

**The rollback is not optional.** `rails runner` writes outside RSpec's transactions, and a leftover row breaks unrelated specs later — which happened twice during phase 1.

- [ ] **Step 6: Run both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: RSpec 0 failures. Cucumber **232 / 2342**. `zeitwerk:check` reports `All is good!`.

- [ ] **Step 7: Boot the production environment**

Neither suite evaluates `config/environments/production.rb`, and this phase changes the schema twice:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u SMTP_PASSWORD=p \
  SMTP_ADDRESS=s MAIL_FROM=m@e.com DATABASE_URL="sqlite3:/tmp/probe.sqlite3" \
  bin/rails runner 'puts "ok"'
rm -f /tmp/probe.sqlite3
```

Expected: `ok`.

- [ ] **Step 8: Commit**

```bash
git add db/migrate spec/models/game_passing/unique_per_run_spec.rb db/schema.rb
git commit -m "Enforce one passing per team per run

The invariant was held only by find_or_create_game_passing's read, so
two near-simultaneous first requests could each miss and create one.

The migration checks for duplicates and says so rather than raising:
migrations run under db:prepare before puma starts, so an index that
raises on unexpected data takes the app down mid-deploy."
```

---

## Before deploying

**Rehearse both migrations against a copy of production**, the same way phase 1 was rehearsed:

```bash
ssh mezin 'RESTORE_POINT=latest KEEP_SCRATCH=yes bash -s' < ops/db-restore-scratch.sh
```

Then run the migrations against the scratch container from the app image and check:

```sql
SELECT count(*) FROM logs WHERE game_id IS NOT NULL AND game_run_id IS NULL;   -- must be 0
SELECT count(*) FROM game_passings WHERE game_run_id IS NULL;                  -- must be 0
SELECT count(*) FROM (SELECT team_id, game_run_id FROM game_passings
                       WHERE game_run_id IS NOT NULL
                       GROUP BY team_id, game_run_id HAVING count(*) > 1) d;   -- must be 0
```

The third is the one that decides whether the unique index is added or skipped. If it is non-zero, the migration will `say` and complete — the app stays up, but the index is absent and someone has to resolve the duplicates.

Destroy the scratch container and volume afterwards, and remove anything copied to the host.

**Rollback** after deploying is `kamal rollback`: both migrations are additive — a column, two indexes — and phase 2 reads nothing the previous code wrote differently. Unlike phase 1 there is no lost-edit window, because nothing here moves a source of truth.
