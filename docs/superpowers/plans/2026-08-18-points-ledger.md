# Points Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Award points for passing levels and finishing games, record them in an append-only ledger, and show the resulting balances on a public chart.

**Architecture:** One new table, `point_transactions`, holding signed amounts with a reason. Awards are written from `GamePassing#pass_level!` — the single point every level advance already goes through — and made idempotent by two partial unique indexes rather than a Ruby check. `teams#index` grows into the chart; a new public `teams#show` carries one team's history and its itemised ledger.

**Tech Stack:** Rails 8.0, Ruby 3.3.12 (rbenv), RSpec, Cucumber (Russian Gherkin, frozen), sqlite in dev/test, YAML locale files.

**Spec:** `docs/superpowers/specs/2026-08-18-points-ledger-design.md`
**Programme umbrella:** `docs/superpowers/specs/2026-08-18-commercial-games-programme-design.md`

## Global Constraints

- **Work in the worktree** `/home/mezinster/encounter-engine-points`, branch `feature/points-ledger`, which sits directly on `master`. Never commit to `master`. Other sessions hold sibling worktrees.
- **Ruby is not on `PATH` in non-login shells.** Every command assumes you first ran:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any `features/**/*.feature` file.** They are a byte-identical acceptance contract from the pre-port Merb app. This plan touches none — and Task 3 hooks into `pass_level!`, which those 228 scenarios drive constantly, so a failure there means the hook is wrong, not the contract.
- **Stage commits by explicit path**, never `git add -A` — this worktree is shared with other sessions.
- **Hash rockets** (`:key => value`) throughout application code — match the surrounding file.
- **Seven locales, always:** `ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a **subset** check for the other five, so a key missing from `uk`/`ka`/`tr`/`be`/`pl` leaves the suite green. Completeness there is on you.
- **The ledger never reverses** (spec P3). No compensating entries, no confirmation state, no `updated_at` on the table.
- **`amount` is one signed integer** (P6). A deduction is a negative row, never a second column or a type flag.
- **Nothing is written when `points_enabled` is false** (spec §3), and the check happens before any row is built.
- **Assert literal Russian in specs, never `I18n.t(key)`** — `ru` is the default locale in test, and `include(I18n.t(key))` cannot fail when a key is missing.
- **`create_user` takes no arguments** and sets the password to `"1234"`. `create_game(options)` accepts `:is_draft => true/false` and `:access_mode`; `create_team(:captain =>)`, `create_level(:game =>)`, `create_game_passing(options)` all live in `spec/spec_helpers/fixtures_helper.rb`.
- **Do NOT run the full RSpec suite and do NOT run Cucumber from a task.** Run the targeted commands each task names, **in the foreground** — never background a suite run and never wait on one. The controller runs the full-suite gates between tasks, with `bin/rails db:test:prepare` before each.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `db/migrate/20260820100000_create_point_transactions.rb` | Create: the ledger table and its two partial unique indexes | 1 |
| `app/models/point_transaction.rb` | Create: the ledger row, its reasons, its award constructor | 1 |
| `app/models/team.rb` | Modify: `has_many :point_transactions`, `#balance` | 1 |
| `db/migrate/20260818180000_add_scoring_to_games_and_levels.rb` | Create: the four config columns | 2 |
| `app/views/games/{new,edit}.html.erb` | Modify: three scoring fields | 2 |
| `app/views/levels/{new,edit}.html.erb` | Modify: the per-level override | 2 |
| `app/controllers/{games,levels}_controller.rb` | Modify: permit lists | 2 |
| `app/models/game_passing.rb` | Modify: `pass_level!` awards | 3 |
| `app/controllers/teams_controller.rb` | Modify: `#index` aggregates; Create: `#show` | 4, 5 |
| `app/views/teams/index.html.erb` | Modify: the chart columns | 4 |
| `app/views/teams/show.html.erb` | Create: one team's history and ledger | 5 |
| `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` | Modify: keys per task | 2, 4, 5 |

**Order follows the spec's §8.** Tasks 1–3 are the ledger and what writes to it, where a defect records wrong numbers the spec forbids reversing. Tasks 4–5 are read-only screens over what those record.

---

## Task 1: `point_transactions` and `Team#balance`

**Files:**
- Create: `db/migrate/20260820100000_create_point_transactions.rb`, `app/models/point_transaction.rb`
- Modify: `db/schema.rb` (regenerated), `app/models/team.rb`, `app/models/game.rb`, `app/models/game_passing.rb` (associations), `spec/spec_helpers/fixtures_helper.rb`
- Test: `spec/models/point_transaction_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: table `point_transactions`; `PointTransaction::REASONS` (`%w[level_completed game_completed]`); `PointTransaction.award!(passing:, reason:, level: nil, amount:)` → the row or nil when a duplicate was refused; `Team#balance` → Integer; fixture `create_point_transaction(options)`. Tasks 3, 4 and 5 use these.

- [ ] **Step 1: Write the failing test**

Create `spec/models/point_transaction_spec.rb`:

```ruby
require "rails_helper"

describe PointTransaction do
  let(:level)   { create_level }
  let(:game)    { level.game }
  let(:passing) { create_game_passing(:game => game, :level => level) }

  describe ".award!" do
    it "records a signed amount against the team, game and attempt" do
      row = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                    :level => level, :amount => 10)

      expect(row.team_id).to eq(passing.team_id)
      expect(row.game_id).to eq(game.id)
      expect(row.game_passing_id).to eq(passing.id)
      expect(row.level_id).to eq(level.id)
      expect(row.amount).to eq(10)
    end

    it "accepts a negative amount, because a deduction is a negative row" do
      row = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                    :level => level, :amount => -5)
      expect(row.amount).to eq(-5)
    end

    it "refuses an unknown reason" do
      expect {
        PointTransaction.award!(:passing => passing, :reason => "invented",
                                :level => level, :amount => 1)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  # Two guards, because game_completed carries a nil level_id and SQL compares
  # NULLs as DISTINCT -- one index would catch the level case and silently
  # miss the completion case. See the design, P5.
  describe "idempotency" do
    it "records a level award once per attempt" do
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)

      expect(PointTransaction.where(:reason => "level_completed").count).to eq(1)
    end

    # The one a single index would miss.
    it "records a completion award once per attempt" do
      PointTransaction.award!(:passing => passing, :reason => "game_completed",
                              :level => nil, :amount => 50)
      PointTransaction.award!(:passing => passing, :reason => "game_completed",
                              :level => nil, :amount => 50)

      expect(PointTransaction.where(:reason => "game_completed").count).to eq(1)
    end

    it "returns nil for the refused duplicate rather than raising" do
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      second = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                       :level => level, :amount => 10)

      expect(second).to be_nil
    end

    it "lets a different level in the same attempt be awarded" do
      other = create_level(:game => game)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => other, :amount => 10)

      expect(PointTransaction.count).to eq(2)
    end

    # A replay is a different attempt, so it earns its own awards.
    it "lets a second attempt at the same game be awarded" do
      second_attempt = create_game_passing(:game => game, :level => level)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => second_attempt, :reason => "level_completed",
                              :level => level, :amount => 10)

      expect(PointTransaction.count).to eq(2)
    end
  end

  describe "Team#balance" do
    it "is zero for a team with no transactions" do
      expect(create_team.balance).to eq(0)
    end

    it "sums signed amounts" do
      team = passing.team
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => passing, :reason => "game_completed",
                              :level => nil, :amount => -3)

      expect(team.reload.balance).to eq(7)
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/models/point_transaction_spec.rb`
Expected: FAIL — `NameError: uninitialized constant PointTransaction`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260820100000_create_point_transactions.rb`:

```ruby
# An append-only ledger. Rows are written and never updated or reversed -- see
# the design, P3 -- which is why there is no updated_at: omitting it makes
# that structural rather than conventional.
class CreatePointTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :point_transactions do |t|
      t.integer  :team_id,         :null => false
      t.integer  :game_id,         :null => false
      t.integer  :game_passing_id, :null => false
      # Nullable: game_completed is not about a level.
      t.integer  :level_id
      # Signed. A deduction is a negative row, so a balance is one SUM and
      # never a case statement -- see the design, P6.
      t.integer  :amount,          :null => false
      t.string   :reason,          :null => false
      # An award earned by play has no actor; an operator adjustment would.
      # Nothing writes this yet -- see the design, §2.1.
      t.integer  :created_by_id
      t.datetime :created_at,      :null => false
    end

    # TWO partial unique indexes, not one, and the reason is a NULL.
    #
    # game_completed carries a nil level_id, and SQL compares NULLs as
    # DISTINCT in a unique index -- so a single index on
    # (game_passing_id, level_id, reason) would refuse a duplicate level award
    # and silently permit a duplicate completion award.
    add_index :point_transactions, [ :game_passing_id, :level_id, :reason ],
              :unique => true, :where => "level_id IS NOT NULL",
              :name => "index_point_transactions_per_level"
    add_index :point_transactions, [ :game_passing_id, :reason ],
              :unique => true, :where => "level_id IS NULL",
              :name => "index_point_transactions_per_attempt"

    add_index :point_transactions, :team_id
  end
end
```

Then `bin/rails db:migrate && bin/rails db:test:prepare`. Confirm `db/schema.rb` gained the table with **both** partial indexes.

- [ ] **Step 4: Write the model**

Create `app/models/point_transaction.rb`:

```ruby
# -*- encoding : utf-8 -*-
# One entry in an append-only points ledger.
#
# Never updated, never reversed. A team that abandons a run keeps what it
# earned and simply never earns the completion award -- see the design, P3/P4.
class PointTransaction < ApplicationRecord
  # D1's two. Sub-project D2 adds the skip fine; an operator adjustment would
  # add another. Both are negative rows in this same table, which is why
  # `amount` is signed.
  REASONS = %w[level_completed game_completed].freeze

  belongs_to :team
  belongs_to :game
  belongs_to :game_passing
  belongs_to :level,      :optional => true
  belongs_to :created_by, :class_name => "User", :optional => true

  validates :amount, :presence => true, :numericality => { :only_integer => true }
  validates :reason, :inclusion => { :in => REASONS }

  # Writes the row, or returns nil when one already exists for this
  # (attempt, level, reason).
  #
  # The duplicate is caught by the database, not by an `exists?` check: two
  # concurrent requests both pass a Ruby check and both insert. RecordNotUnique
  # here means the award is already recorded, which is exactly the outcome
  # wanted -- so it is rescued and nothing else is.
  #
  # team_id and game_id are denormalised from the passing so the chart and the
  # per-team history can aggregate without joining through game_passings.
  def self.award!(passing:, reason:, amount:, level: nil)
    create!(:team_id         => passing.team_id,
            :game_id         => passing.game_id,
            :game_passing_id => passing.id,
            :level_id        => level&.id,
            :amount          => amount,
            :reason          => reason)
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
```

- [ ] **Step 5: Wire the associations and the fixture**

`app/models/team.rb`, beside the other `has_many`s:

```ruby
  has_many :point_transactions

  # The ledger is the source of truth. A cached column may follow if this ever
  # measurably hurts; it is not an optimisation to make in advance.
  def balance
    point_transactions.sum(:amount)
  end
```

`app/models/game.rb` and `app/models/game_passing.rb`, beside their existing associations:

```ruby
  has_many :point_transactions
```

**Not `dependent: :destroy` on any of the three.** A ledger row is a record of something that happened; `Team#deletable?` and `Game#deletable?` already refuse to delete an owner that still holds history, and this codebase's rule is refuse, don't cascade. Add `point_transactions.empty?` to **both** predicates.

**`Game#deletable?` is called once per row in the operator's game listings**, so its new conjunct must be preloaded in `Admin::GamesController#index`, which already preloads `game_passings`, `access_passes` and `access_codes` for exactly this reason. Add `point_transactions` beside them, and run the query-count specs named in Step 6 — this same omission has broken them twice before.

In `spec/spec_helpers/fixtures_helper.rb`:

```ruby
  def create_point_transaction(options = {})
    passing = options[:passing] || create_game_passing
    PointTransaction.award!(:passing => passing,
                            :reason  => options[:reason] || "level_completed",
                            :level   => options.key?(:level) ? options[:level] : passing.current_level,
                            :amount  => options[:amount] || 10)
  end
```

- [ ] **Step 6: Run the specs**

Run: `bundle exec rspec spec/models/point_transaction_spec.rb spec/models/team spec/models/game spec/requests/game_deletion_spec.rb spec/requests/admin_console_spec.rb spec/requests/admin_entries_console_spec.rb`
Expected: 0 failures. The two admin-console specs pin a flat query count and are in this list because of the preload above.

Add a covering example that a team holding a ledger row is not deletable, and one for a game, each proven to discriminate by removing the conjunct and confirming only that example fails.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260820100000_create_point_transactions.rb db/schema.rb \
        app/models/point_transaction.rb app/models/team.rb app/models/game.rb \
        app/models/game_passing.rb app/controllers/admin/games_controller.rb \
        spec/models/point_transaction_spec.rb spec/spec_helpers/fixtures_helper.rb \
        spec/requests/game_deletion_spec.rb
git commit -m "Add the point_transactions ledger

Append-only: rows are written and never updated or reversed, which is
why the table has no updated_at. amount is signed, so a deduction is a
negative row and a balance is one SUM.

Idempotency is enforced by TWO partial unique indexes. game_completed
carries a nil level_id, and SQL compares NULLs as distinct, so a single
index would have refused duplicate level awards while silently
permitting duplicate completion awards.

Neither Team nor Game cascades to the ledger: a row records something
that happened, and both deletable? predicates now refuse an owner that
holds one. Game#deletable? is evaluated per row in the operator
listings, so its association is preloaded alongside the three that are
already there.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: the scoring configuration

**Files:**
- Create: `db/migrate/20260818180000_add_scoring_to_games_and_levels.rb`
- Modify: `app/models/game.rb` (`#points_for_level`), `app/views/games/{new,edit}.html.erb`, `app/views/levels/{new,edit}.html.erb`, `app/controllers/games_controller.rb` (permit list), `app/controllers/levels_controller.rb` (permit list)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/models/game/scoring_spec.rb`, `spec/requests/scoring_config_spec.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `games.points_enabled` (boolean, `default: false, null: false`), `games.level_completion_points` and `games.game_completion_points` (integer, `default: 0, null: false`), `levels.points_award` (integer, nullable); `Game#points_for_level(level)` → Integer. Task 3 calls that method.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game/scoring_spec.rb`:

```ruby
require "rails_helper"

describe Game do
  describe "scoring configuration" do
    it "is off by default, and awards nothing" do
      game = create_game
      expect(game.points_enabled).to be false
      expect(game.level_completion_points).to eq(0)
      expect(game.game_completion_points).to eq(0)
    end
  end

  describe "#points_for_level" do
    let(:game)  { create_game(:points_enabled => true, :level_completion_points => 10) }
    let(:level) { create_level(:game => game) }

    it "uses the game's default when the level sets none" do
      expect(level.points_award).to be_nil
      expect(game.points_for_level(level)).to eq(10)
    end

    it "uses the level's override when it is set" do
      level.update!(:points_award => 25)
      expect(game.points_for_level(level)).to eq(25)
    end

    # nil means "use the game's value"; 0 means zero. An author must be able
    # to make one level worth nothing without turning scoring off entirely.
    it "treats an override of zero as zero, not as absent" do
      level.update!(:points_award => 0)
      expect(game.points_for_level(level)).to eq(0)
    end
  end
end
```

Create `spec/requests/scoring_config_spec.rb`:

```ruby
require "rails_helper"

describe "configuring scoring", type: :request do
  let(:author) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "lets an author turn scoring on and set the values" do
    game = create_game(:author => author, :is_draft => true)
    sign_in(author)

    patch game_path(game), :params => { :game => { :points_enabled => "1",
                                                   :level_completion_points => "10",
                                                   :game_completion_points => "50" } }

    game.reload
    expect(game.points_enabled).to be true
    expect(game.level_completion_points).to eq(10)
    expect(game.game_completion_points).to eq(50)
  end

  it "lets an author set a per-level override" do
    game  = create_game(:author => author, :is_draft => true, :points_enabled => true)
    level = create_level(:game => game)
    sign_in(author)

    patch game_level_path(game, level), :params => { :level => { :points_award => "25" } }

    expect(level.reload.points_award).to eq(25)
  end
end
```

If the level update route helper differs, read `config/routes.rb` and use the real one — do not invent helpers. `spec/requests/quiz_authoring_spec.rb` drives level updates and shows the shape.

- [ ] **Step 2: Run both and confirm they fail for the right reason**

Run: `bundle exec rspec spec/models/game/scoring_spec.rb spec/requests/scoring_config_spec.rb`
Expected: FAIL — `unknown attribute 'points_enabled'`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260818180000_add_scoring_to_games_and_levels.rb`:

```ruby
class AddScoringToGamesAndLevels < ActiveRecord::Migration[8.0]
  def change
    # Off by default: no existing game starts writing ledger rows behind its
    # author's back. See the design, P1.
    add_column :games, :points_enabled,          :boolean, :default => false, :null => false
    add_column :games, :level_completion_points, :integer, :default => 0,     :null => false
    add_column :games, :game_completion_points,  :integer, :default => 0,     :null => false

    # Nullable ON PURPOSE: nil means "use the game's value", 0 means zero.
    # An author must be able to make one level worth nothing without turning
    # scoring off for the whole game.
    add_column :levels, :points_award, :integer
  end
end
```

Then `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 4: Add the resolver**

In `app/models/game.rb`:

```ruby
  # What passing this level is worth. The level's own value wins when it has
  # one -- INCLUDING zero, which is why this tests for nil rather than using
  # `||`. NOTE: as shipped this comment was corrected -- `0` is truthy in Ruby,
  # so `||` is in fact equivalent. What collapses nil and zero is a `.zero?` or
  # `> 0` test. See app/models/game.rb for the accurate wording.
  def points_for_level(level)
    return level.points_award unless level&.points_award.nil?

    level_completion_points
  end
```

- [ ] **Step 5: Add the form fields and permit them**

`app/views/games/new.html.erb` and `edit.html.erb`, beside the existing fields (read `games/edit.html.erb` first and match its markup):

```erb
  <p>
    <%= f.label :points_enabled, t("games.form.points_enabled") %>
    <%= f.check_box :points_enabled %>
  </p>
  <p>
    <%= f.label :level_completion_points, t("games.form.level_completion_points") %>
    <%= f.number_field :level_completion_points, :min => 0 %>
  </p>
  <p>
    <%= f.label :game_completion_points, t("games.form.game_completion_points") %>
    <%= f.number_field :game_completion_points, :min => 0 %>
  </p>
```

`app/views/levels/new.html.erb` and `edit.html.erb`, beside `wrong_answer_penalty_in_minutes`:

```erb
  <p>
    <%= f.label :points_award, t("levels.form.points_award") %>
    <%= f.number_field :points_award, :min => 0 %>
  </p>
```

**Render these as a single field each, not inside a new "scoring" fieldset.** The game form already groups by nothing in particular, and a section invented here would be the obvious home for later settings that do not belong behind the same conditions.

Add `:points_enabled`, `:level_completion_points` and `:game_completion_points` to `GamesController`'s permit list, and `:points_award` to `LevelsController`'s. Read each list first — `games_controller.rb`'s is inside `game_attributes`, which transforms params before permitting.

- [ ] **Step 6: Add the four keys to all seven locales**

| Key | ru | en |
|---|---|---|
| `games.form.points_enabled` | Начислять очки | Award points |
| `games.form.level_completion_points` | Очков за уровень | Points per level |
| `games.form.game_completion_points` | Очков за прохождение | Points for finishing |
| `levels.form.points_award` | Очков за этот уровень (по умолчанию — как в игре) | Points for this level (blank = the game's value) |

The remaining five, same order:

- `uk`: Нараховувати очки / Очок за рівень / Очок за проходження / Очок за цей рівень (порожньо — як у грі)
- `ka`: ქულების დარიცხვა / ქულა დონისთვის / ქულა დასრულებისთვის / ქულა ამ დონისთვის (ცარიელი — თამაშის მნიშვნელობა)
- `tr`: Puan ver / Seviye başına puan / Bitirme puanı / Bu seviyenin puanı (boş = oyunun değeri)
- `be`: Налічваць ачкі / Ачкоў за ўзровень / Ачкоў за праходжанне / Ачкоў за гэты ўзровень (пуста — як у гульні)
- `pl`: Przyznawaj punkty / Punktów za poziom / Punktów za ukończenie / Punktów za ten poziom (puste = wartość gry)

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/models/game/scoring_spec.rb spec/requests/scoring_config_spec.rb spec/views/games_spec.rb spec/requests/quiz_authoring_spec.rb spec/i18n_spec.rb`
Expected: 0 failures. `spec/views/games_spec.rb` renders the game form and will catch a missing translation, which the test environment raises on.

- [ ] **Step 8: Commit**

```bash
git add -- db/migrate/20260818180000_add_scoring_to_games_and_levels.rb db/schema.rb \
        app/models/game.rb app/views/games app/views/levels \
        app/controllers/games_controller.rb app/controllers/levels_controller.rb \
        spec/models/game/scoring_spec.rb spec/requests/scoring_config_spec.rb \
        config/locales
git commit -m "Add the scoring configuration

Off by default, so no existing game starts writing ledger rows behind
its author's back.

levels.points_award is nullable on purpose: nil means the game's value,
zero means zero. points_for_level tests for nil rather than using ||,
because a resolver testing for non-zero (`.zero?`, `to_i > 0`) would turn a
deliberate zero into the default. (`||` would not -- 0 is truthy in Ruby.)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: the awards

**Files:**
- Modify: `app/models/game_passing.rb` — `pass_level!`
- Test: `spec/models/game_passing/awards_spec.rb`

**Interfaces:**
- Consumes: `PointTransaction.award!` (Task 1), `Game#points_for_level` and the config columns (Task 2).
- Produces: ledger rows. Tasks 4 and 5 read them.

**This task hooks into the method the frozen acceptance contract drives constantly.** 228 inherited scenarios pass levels. If any of them fails after this, the hook is wrong — not the contract.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game_passing/awards_spec.rb`:

```ruby
require "rails_helper"

describe GamePassing do
  def scoring_game
    game = create_game(:points_enabled => true,
                       :level_completion_points => 10,
                       :game_completion_points => 50)
    first  = create_level(:game => game, :position => 1)
    second = create_level(:game => game, :position => 2)
    [ game, first, second ]
  end

  it "awards the level value on passing a level" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)

    expect { passing.pass_level! }.to change { PointTransaction.count }.by(1)

    row = PointTransaction.last
    expect(row.reason).to eq("level_completed")
    expect(row.amount).to eq(10)
    expect(row.level_id).to eq(first.id)
  end

  it "awards the level value AND the completion value on the last level" do
    game, _first, second = scoring_game
    passing = create_game_passing(:game => game, :level => second)

    expect { passing.pass_level! }.to change { PointTransaction.count }.by(2)

    expect(PointTransaction.where(:reason => "game_completed").first.amount).to eq(50)
    expect(PointTransaction.where(:reason => "game_completed").first.level_id).to be_nil
  end

  it "honours a per-level override" do
    game, first, _second = scoring_game
    first.update!(:points_award => 25)
    passing = create_game_passing(:game => game, :level => first)

    passing.pass_level!

    expect(PointTransaction.last.amount).to eq(25)
  end

  it "writes nothing at all when scoring is off" do
    game, first, _second = scoring_game
    game.update!(:points_enabled => false)
    passing = create_game_passing(:game => game, :level => first)

    expect { passing.pass_level! }.not_to change { PointTransaction.count }
  end

  # The idempotency guard, exercised the way it can actually fail: an operator
  # sends a team back and they pass the same level again.
  it "awards a level once even when the team is moved back and re-passes it" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)
    passing.pass_level!

    passing.move_to_level!(first)
    passing.pass_level!

    expect(PointTransaction.where(:reason => "level_completed", :level_id => first.id).count).to eq(1)
  end

  # The half a single index would miss.
  it "awards the completion once even when the attempt is completed twice" do
    game, _first, second = scoring_game
    passing = create_game_passing(:game => game, :level => second)
    passing.pass_level!

    passing.move_to_level!(second)
    passing.pass_level!

    expect(PointTransaction.where(:reason => "game_completed").count).to eq(1)
  end

  # P4: the ledger never reverses, so a team that quits keeps what it earned
  # and simply never earns the completion award. This is the example that
  # would catch anyone "tidying up" abandoned runs later.
  it "leaves earned points alone when the team abandons the run" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)
    passing.pass_level!

    expect { passing.exit! }.not_to change { PointTransaction.count }
    expect(passing.team.reload.balance).to eq(10)
    expect(PointTransaction.where(:reason => "game_completed").count).to eq(0)
  end

  # A team standing in a street with a correct answer must advance whether or
  # not the ledger accepts a row.
  it "still advances the team when the award is a duplicate" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)
    passing.pass_level!
    passing.move_to_level!(first)

    passing.pass_level!

    expect(passing.reload.current_level_id).not_to eq(first.id)
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/models/game_passing/awards_spec.rb`
Expected: FAIL — the count assertions fail because nothing writes a row yet.

- [ ] **Step 3: Add the hook**

In `app/models/game_passing.rb`, `pass_level!` currently reads:

```ruby
  def pass_level!
    if last_level?
      set_finish_time
    else
      update_current_level_entered_at
    end

    reset_answered_questions

    self.current_level = self.current_level.next
    save!
  end
```

Add the awards, keeping every existing line in place:

```ruby
  def pass_level!
    passed = self.current_level
    finishing = last_level?

    if finishing
      set_finish_time
    else
      update_current_level_entered_at
    end

    reset_answered_questions

    self.current_level = self.current_level.next
    save!

    award_points_for(passed, finishing)
  end
```

and, in the private section:

```ruby
  # Awards are written AFTER the advance is saved, deliberately. A team
  # standing in a street with a correct answer must move on whether or not the
  # ledger accepts a row; nothing about scoring may block play.
  #
  # PointTransaction.award! returns nil on a duplicate rather than raising, so
  # a re-passed level -- an operator sent them back -- awards once and the team
  # still advances. See the design, P5.
  def award_points_for(level, finishing)
    return unless game&.points_enabled?

    PointTransaction.award!(:passing => self, :reason => "level_completed",
                            :level => level, :amount => game.points_for_level(level))

    return unless finishing

    PointTransaction.award!(:passing => self, :reason => "game_completed",
                            :level => nil, :amount => game.game_completion_points)
  end
```

- [ ] **Step 4: Run the specs**

Run: `bundle exec rspec spec/models/game_passing spec/models/point_transaction_spec.rb spec/requests/answer_feedback_spec.rb spec/requests/gated_play_spec.rb`
Expected: 0 failures. The two request specs drive real level passes and are the closest thing to the acceptance contract you may run from a task.

- [ ] **Step 5: Commit**

```bash
git add -- app/models/game_passing.rb spec/models/game_passing/awards_spec.rb
git commit -m "Award points on passing a level and finishing a game

Hooked into pass_level!, the single point every advance already goes
through, so both awards fall out of the branch that was already there.

Written after the advance is saved: a team standing in a street with a
correct answer must move on whether or not the ledger accepts a row.
award! returns nil on a duplicate rather than raising, so a level
re-passed after an operator moved the team back awards once and the
team still advances.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: the chart

**Files:**
- Modify: `app/controllers/teams_controller.rb` — `#index`
- Modify: `app/views/teams/index.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/points_chart_spec.rb`, and the existing `spec/requests/teams_index_spec.rb`

**Interfaces:**
- Consumes: `PointTransaction`, `Team#balance` (Task 1); ledger rows written by Task 3.
- Produces: nothing later tasks read.

`teams#index` already exists, already preloads `:captain` and `:members`, and already carries what its own comment calls a **slope guard** in `spec/requests/teams_index_spec.rb` — an example pinning that its query count does not grow with the number of teams. Everything you add must keep that true.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/points_chart_spec.rb`:

```ruby
require "rails_helper"

describe "the points chart", type: :request do
  let(:viewer) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def scoring_game
    game  = create_game(:points_enabled => true, :level_completion_points => 10,
                        :game_completion_points => 50)
    level = create_level(:game => game, :position => 1)
    [ game, level ]
  end

  it "shows a team's balance" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    sign_in(viewer)

    get teams_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(passing.team.name)
    expect(response.body).to include("10")
  end

  it "shows a team with no transactions at zero rather than omitting it" do
    team = create_team(:captain => create_user)
    sign_in(viewer)

    get teams_path

    expect(response.body).to include(team.name)
  end

  it "breaks ties on name, so an all-zero chart is alphabetical" do
    # create_team IGNORES a :name option -- it always generates "Team#<random>"
    # -- so the names are set afterwards. Passing :name to the helper would
    # leave two random names and an assertion that proves nothing.
    b = create_team(:captain => create_user); b.update!(:name => "Бета")
    a = create_team(:captain => create_user); a.update!(:name => "Альфа")
    sign_in(viewer)

    get teams_path

    expect(response.body.index(a.name)).to be < response.body.index(b.name)
  end

  it "sorts by balance, highest first" do
    game, level = scoring_game
    poor = create_game_passing(:game => game, :level => level)
    rich = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => poor, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => rich, :reason => "level_completed",
                            :level => level, :amount => 90)
    sign_in(viewer)

    get teams_path

    expect(response.body.index(rich.team.name)).to be < response.body.index(poor.team.name)
  end

  it "counts deductions against the balance" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => passing, :reason => "game_completed",
                            :level => nil, :amount => -4)
    sign_in(viewer)

    get teams_path

    expect(response.body).to include("6")
  end

  # The chart's figures must be grouped queries. This programme has introduced
  # the same N+1 three times; the existing slope guard in teams_index_spec.rb
  # is what catches a fourth.
  it "keeps the query count flat as the number of teams grows" do
    game, level = scoring_game
    sign_in(viewer)
    2.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level)) }
    small = count_queries { get teams_path }

    6.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level)) }
    large = count_queries { get teams_path }

    expect(large).to eq(small)
  end
end
```

`count_queries` is a shared helper in `spec/support/query_counter.rb` — use it rather than writing another.

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/requests/points_chart_spec.rb`
Expected: FAIL — the balance and sorting assertions fail because the page shows no points.

- [ ] **Step 3: Compute the figures with grouped queries**

In `app/controllers/teams_controller.rb`, `#index`. **Keep the existing preloads and the `@pending_team_ids` query** — both carry comments explaining the queries they exist to avoid.

```ruby
  def index
    @teams = Team.includes(:captain, :members).order(:name)
    @pending_team_ids = TeamJoinRequest.pending.of_user(current_user).pluck(:team_id)

    # Four grouped queries for the whole page, whatever the number of teams.
    # Never a lookup per row: teams_index_spec.rb pins a flat count, and this
    # programme has broken that class of guard three times already.
    @earned    = PointTransaction.where("amount > 0").group(:team_id).sum(:amount)
    @deducted  = PointTransaction.where("amount < 0").group(:team_id).sum(:amount)
    @started   = GamePassing.group(:team_id).count
    @finished  = GamePassing.completed.group(:team_id).count

    # Sorted in Ruby, from figures already loaded, rather than by adding a
    # join and an ORDER BY to the relation above: the page renders tens of
    # teams, and a join here would fight the preloads.
    #
    # Name is the tie-break, so teams on equal points -- which at launch is
    # every team, all on zero -- keep the alphabetical order the relation
    # already applied instead of coming back in whatever order the sort felt
    # like.
    @teams = @teams.to_a.sort_by { |t| [ -balance_of(t), t.name.to_s ] }
  end

  private

  # Earned is positive, deducted is negative, so the balance is their sum.
  def balance_of(team)
    @earned.fetch(team.id, 0) + @deducted.fetch(team.id, 0)
  end
  helper_method :balance_of
```

`GamePassing.completed` already exists and excludes abandoned attempts — read its comment before using it; it is the same scope sub-project B used for standings.

- [ ] **Step 4: Add the columns to the view**

In `app/views/teams/index.html.erb`, add headers and cells beside the existing ones, matching the `data-label` convention already in that file:

```erb
      <th><%= t("teams.index.games_started") %></th>
      <th><%= t("teams.index.games_finished") %></th>
      <th><%= t("teams.index.points_earned") %></th>
      <th><%= t("teams.index.points_deducted") %></th>
      <th><%= t("teams.index.balance") %></th>
```

```erb
      <td data-label="<%= t("teams.index.games_started") %>"><%= @started.fetch(team.id, 0) %></td>
      <td data-label="<%= t("teams.index.games_finished") %>"><%= @finished.fetch(team.id, 0) %></td>
      <td data-label="<%= t("teams.index.points_earned") %>"><%= @earned.fetch(team.id, 0) %></td>
      <td data-label="<%= t("teams.index.points_deducted") %>"><%= @deducted.fetch(team.id, 0).abs %></td>
      <td data-label="<%= t("teams.index.balance") %>"><%= balance_of(team) %></td>
```

Deductions render as a magnitude (`.abs`) under a column that already says "deducted" — a column of negative numbers headed "points deducted" reads as a double negative.

- [ ] **Step 5: Add the five keys to all seven locales**

| Key | ru | en | uk | ka | tr | be | pl |
|---|---|---|---|---|---|---|---|
| `games_started` | Игр начато | Games started | Ігор почато | დაწყებული | Başlanan | Гульняў пачата | Rozpoczęte |
| `games_finished` | Игр пройдено | Games finished | Ігор пройдено | დასრულებული | Bitirilen | Гульняў пройдзена | Ukończone |
| `points_earned` | Очков заработано | Points earned | Очок зароблено | დაგროვილი ქულა | Kazanılan puan | Ачкоў заробленых | Zdobyte punkty |
| `points_deducted` | Очков снято | Points deducted | Очок знято | ჩამოჭრილი ქულა | Düşülen puan | Ачкоў знята | Odjęte punkty |
| `balance` | Баланс | Balance | Баланс | ბალანსი | Bakiye | Баланс | Bilans |

All under `teams.index`.

- [ ] **Step 6: Run the specs**

Run: `bundle exec rspec spec/requests/points_chart_spec.rb spec/requests/teams_index_spec.rb spec/i18n_spec.rb`
Expected: 0 failures. `teams_index_spec.rb` holds the pre-existing slope guard; if it goes red, a figure is being computed per row.

- [ ] **Step 7: Commit**

```bash
git add -- app/controllers/teams_controller.rb app/views/teams/index.html.erb \
        spec/requests/points_chart_spec.rb config/locales
git commit -m "Turn the teams listing into the points chart

Four grouped queries for the whole page whatever the number of teams,
never a lookup per row -- teams_index_spec.rb already pins a flat count
and this programme has broken that class of guard three times.

Sorted in Ruby from figures already loaded rather than by joining and
ordering the relation, which would fight the existing preloads.

Teams with no transactions appear at zero: it is a list of teams, not a
list of scorers.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: one team's history and ledger

**Files:**
- Modify: `app/controllers/teams_controller.rb` — add `#show`
- Create: `app/views/teams/show.html.erb`
- Modify: `app/views/teams/index.html.erb` (link the team name)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/team_history_spec.rb`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: nothing. This is the last task.

**`TeamsController` has no `show` today**, and `resources :teams` (`config/routes.rb:101`) already routes one — so `GET /teams/:id` currently reaches a missing action, exactly as `index` did before somebody filled that slot. You are filling it, not adding a route.

**The whole ledger is public** (spec P9), itemised rows included. `TeamRoomController` is the team's own room and is members-only; it is not this page and must not be changed.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/team_history_spec.rb`:

```ruby
require "rails_helper"

describe "a team's history", type: :request do
  def scoring_game
    game  = create_game(:points_enabled => true, :level_completion_points => 10,
                        :game_completion_points => 50)
    level = create_level(:game => game, :position => 1)
    [ game, level ]
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "is reachable and names the team" do
    team = create_team(:captain => create_user)

    get team_path(team)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(team.name)
  end

  it "lists the games the team has played, with what each was worth" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)

    get team_path(passing.team)

    expect(response.body).to include(game.name)
    expect(response.body).to include("10")
  end

  # P9: the whole ledger is public, itemised rows included.
  it "shows the itemised ledger to a signed-out visitor" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)

    get team_path(passing.team)

    expect(response.body).to include("Очко за уровень")
  end

  it "shows a team with no history without erroring" do
    team = create_team(:captain => create_user)

    get team_path(team)

    expect(response).to have_http_status(:ok)
  end

  it "keeps the query count flat as the team's history grows" do
    game, level = scoring_game
    team = create_team(:captain => create_user)
    2.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level, :team => team)) }
    small = count_queries { get team_path(team) }

    6.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level, :team => team)) }
    large = count_queries { get team_path(team) }

    expect(large).to eq(small)
  end
end
```

If `create_game_passing` does not accept `:team`, read the helper and pass the team the way it expects — do not change the helper for this.

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/requests/team_history_spec.rb`
Expected: FAIL — the action is missing, so the request raises rather than rendering.

- [ ] **Step 3: Add the action**

In `app/controllers/teams_controller.rb`. Note the controller's `before_action :require_authentication!` at the top — `show` must be **exempt**, because P9 makes this page public:

```ruby
  before_action :require_authentication!, :except => [ :show ]
```

```ruby
  # Public: the chart links here, and P9 makes the whole ledger readable.
  # TeamRoomController is the team's own room, behind ensure_team_member, and
  # is a different thing.
  def show
    @team = Team.find(params[:id])

    # Preloaded because the view names each game and each level: without this
    # the ledger table issues two queries per row.
    @transactions = @team.point_transactions.includes(:game, :level).order(:created_at => :desc)

    # One row per attempt, with what that attempt was worth -- a grouped sum,
    # not a per-attempt lookup.
    @passings = @team.game_passings.includes(:game).order(:created_at => :desc)
    @per_attempt = @team.point_transactions.group(:game_passing_id).sum(:amount)
  end
```

- [ ] **Step 4: Write the view**

Create `app/views/teams/show.html.erb`:

```erb
<h1><%= @team.name %></h1>

<p><%= t("teams.show.balance") %>: <%= @team.balance %></p>

<h2><%= t("teams.show.games") %></h2>

<div class="table-wrap">
<table class="table--cards">
  <thead>
    <tr>
      <th><%= t("teams.show.game") %></th>
      <th><%= t("teams.show.started") %></th>
      <th><%= t("teams.show.finished") %></th>
      <th><%= t("teams.show.points") %></th>
    </tr>
  </thead>
  <tbody>
  <% @passings.each do |passing| %>
    <tr>
      <td data-label="<%= t("teams.show.game") %>"><%= passing.game&.name %></td>
      <td data-label="<%= t("teams.show.started") %>"><%= l(passing.created_at, :format => :long) %></td>
      <td data-label="<%= t("teams.show.finished") %>">
        <%= passing.finished_at ? l(passing.finished_at, :format => :long) : t("teams.show.unfinished") %>
      </td>
      <td data-label="<%= t("teams.show.points") %>"><%= @per_attempt.fetch(passing.id, 0) %></td>
    </tr>
  <% end %>
  </tbody>
</table>
</div>

<h2><%= t("teams.show.ledger") %></h2>

<div class="table-wrap">
<table class="table--cards">
  <thead>
    <tr>
      <th><%= t("teams.show.when") %></th>
      <th><%= t("teams.show.game") %></th>
      <th><%= t("teams.show.reason") %></th>
      <th><%= t("teams.show.amount") %></th>
    </tr>
  </thead>
  <tbody>
  <% @transactions.each do |row| %>
    <tr>
      <td data-label="<%= t("teams.show.when") %>"><%= l(row.created_at, :format => :long) %></td>
      <td data-label="<%= t("teams.show.game") %>"><%= row.game&.name %></td>
      <%# Rendered from a fixed set, never interpolated from the column: an
          unrecognised reason must not print "translation missing" on a public
          page. See the design, §6. %>
      <td data-label="<%= t("teams.show.reason") %>">
        <%= PointTransaction::REASONS.include?(row.reason) ? t("teams.show.reasons.#{row.reason}") : row.reason %>
      </td>
      <td data-label="<%= t("teams.show.amount") %>"><%= row.amount %></td>
    </tr>
  <% end %>
  </tbody>
</table>
</div>
```

In `app/views/teams/index.html.erb`, make the team name a link to `team_path(team)`.

- [ ] **Step 5: Add the keys to all seven locales**

Under `teams.show`, plus the two reason labels under `teams.show.reasons`:

| Key | ru | en |
|---|---|---|
| `balance` | Баланс | Balance |
| `games` | Сыгранные игры | Games played |
| `game` | Игра | Game |
| `started` | Начало | Started |
| `finished` | Финиш | Finished |
| `unfinished` | не завершена | not finished |
| `points` | Очков | Points |
| `ledger` | Начисления | Ledger |
| `when` | Когда | When |
| `reason` | За что | Reason |
| `amount` | Очков | Amount |
| `reasons.level_completed` | Очко за уровень | Level passed |
| `reasons.game_completed` | Очко за прохождение | Game finished |

The remaining five, same order:

- `uk`: Баланс / Зіграні ігри / Гра / Початок / Фініш / не завершена / Очок / Нарахування / Коли / За що / Очок / Очко за рівень / Очко за проходження
- `ka`: ბალანსი / ნათამაშები / თამაში / დაწყება / ფინიში / დაუსრულებელი / ქულა / ჩარიცხვები / როდის / რისთვის / ქულა / ქულა დონისთვის / ქულა დასრულებისთვის
- `tr`: Bakiye / Oynanan oyunlar / Oyun / Başlangıç / Bitiş / bitirilmedi / Puan / Hareketler / Ne zaman / Nedeni / Puan / Seviye puanı / Bitirme puanı
- `be`: Баланс / Згуляныя гульні / Гульня / Пачатак / Фініш / не завершана / Ачкоў / Налічэнні / Калі / За што / Ачкоў / Ачко за ўзровень / Ачко за праходжанне
- `pl`: Bilans / Rozegrane gry / Gra / Początek / Meta / nieukończona / Punktów / Naliczenia / Kiedy / Za co / Punktów / Punkt za poziom / Punkt za ukończenie

The Russian `reasons.level_completed` is what the public-visibility example asserts on, so it must match exactly.

- [ ] **Step 6: Run the specs**

Run: `bundle exec rspec spec/requests/team_history_spec.rb spec/requests/points_chart_spec.rb spec/requests/teams_index_spec.rb spec/requests/team_room_spec.rb spec/i18n_spec.rb`
Expected: 0 failures. `team_room_spec.rb` is included to prove the members-only room is unchanged.

- [ ] **Step 7: Commit**

```bash
git add -- app/controllers/teams_controller.rb app/views/teams \
        spec/requests/team_history_spec.rb config/locales
git commit -m "Add a public team page with its history and ledger

Fills the show action resources :teams already routed -- GET /teams/:id
reached a missing action, exactly as index did before it was filled.
Exempt from require_authentication!, because P9 makes the whole ledger
public, itemised rows included.

Reason labels render from a fixed set rather than interpolating the
column, so an unrecognised reason cannot print translation missing on a
public page.

TeamRoomController is the team's own members-only room and is untouched.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Final Verification

Run by the controller, not by a task subagent. `bin/rails db:test:prepare` before **each** suite — the two share `db/test.sqlite3`, and a contract run straight after RSpec has produced phantom failures in this programme before.

- [ ] **Full RSpec** — `bundle exec rspec`. Expected: 0 failures. Measure the total; do not quote one from `CLAUDE.md`.

- [ ] **The inherited Cucumber contract** — the gate that matters most here, because Task 3 hooks into `pass_level!` and those scenarios pass levels constantly:

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: **228 scenarios (226 passed, 2 undefined) / 2325 steps**, unchanged.

- [ ] **Whole Cucumber suite** — `bundle exec cucumber`. Expected: 0 failures.

- [ ] **Autoloading** — `bin/rails zeitwerk:check`. Expected: "All is good!"

- [ ] **Production boot:**

```bash
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u \
SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com \
DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'
```

- [ ] **No `.feature` file touched** — `git diff master --stat -- 'features/**/*.feature'` must be empty.

- [ ] **Scoring is genuinely off by default** — a game created without naming it must award nothing:

```bash
bin/rails runner -e test 'g = Game.new; puts "points_enabled=#{g.points_enabled.inspect}"'
```

Expected: `points_enabled=false`. This is the check that a default's polarity is what the spec says; an inverted one shipped in this programme before and cost 97 inherited scenarios.

- [ ] **Locale completeness** — `spec/i18n_spec.rb` proves only `ru`↔`en`, so check the other five by hand:

```bash
for k in points_enabled points_earned balance reasons; do
  echo "== $k"; grep -L "$k" config/locales/{ru,en,uk,ka,tr,be,pl}.yml
done
```

Any file printed is missing that key.
