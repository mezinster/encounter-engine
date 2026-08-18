# Access-Gated Commercial Games Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an operator sell a game as a unit — a team is invited, becomes entitled to exactly one private run, plays it whenever they like, and appears in that game's duration-ranked standings.

**Architecture:** Two enum columns on `games` (`visibility`, `access_mode`). A new `access_passes` table holds the entitlement; a commercial attempt is an ordinary `GamePassing` with `game_run_id` NULL and `access_pass_id` set, so the entire scoring loop is untouched. The gate stays where it already is — at passing creation — and `AccessPass#spent?` is derived from the attempt rather than stored.

**Tech Stack:** Rails 8.0, Ruby 3.3.12 (rbenv), RSpec (model + request specs), Cucumber (Russian Gherkin, frozen), sqlite in dev/test, YAML locale files, Nokogiri for DOM-scoped assertions.

**Spec:** `docs/superpowers/specs/2026-08-18-access-gated-games-design.md`
**Programme umbrella:** `docs/superpowers/specs/2026-08-18-commercial-games-programme-design.md`
**Depends on:** `docs/superpowers/specs/2026-08-18-operator-role-design.md` (sub-project A), which shipped `users.is_operator`, `User#operator?` and `User#may_operate_commercial?` **inert**. This plan is where that role acquires authority.

## Global Constraints

- **Work in the worktree** `/home/mezinster/encounter-engine-access-gated`, branch `feature/access-gated-games`, which is **stacked on `feature/operator-role`** (not on `master`). Never commit to `master` or to `feature/operator-role`. Other sessions hold sibling worktrees; do not switch this one's branch.
- **Ruby is not on `PATH` in non-login shells.** Every command assumes you first ran:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any `features/**/*.feature` file**, not even whitespace. They are a byte-identical acceptance contract from the pre-port Merb app. This plan touches none. If one appears to need changing, the implementation is wrong.
- **Hash rockets** (`:key => value`) throughout application code, including for symbol keys — match the surrounding file.
- **Seven locales, always:** `ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`. The test environment sets `raise_on_missing_translations`. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a **subset** check for the other five — so a key missing from `uk`, `ka`, `tr`, `be` or `pl` leaves the suite fully green. Completeness there is on you, not on the tests.
- **Turkish rewords around interpolated names.** Any key carrying `%{team}`, `%{game}` or `%{nickname}` must put the case suffix on a common noun (`«%{team}» adlı takım`), never on the placeholder. The standings and invitation strings both carry names.
- **Assert literal Russian in specs, never `I18n.t(key)`.** `ru` is the default locale in test, and `include(I18n.t(key))` cannot fail when a key is missing — it compares the page against the same missing-translation marker the page contains.
- **`create_user` takes no arguments.** It generates its own nickname and e-mail and sets the password to `"1234"`. `create_game(options)`, `create_team`, `create_level`, `create_game_passing(options)` and `create_game_entry(options)` live in `spec/spec_helpers/fixtures_helper.rb`. Do not introduce FactoryBot.
- **`create_game_passing` defaults `:game_run => game.current_run`.** A commercial attempt needs `:game_run => nil` passed explicitly; `.merge(options)` means an explicit nil wins.
- **Do NOT run the full RSpec suite and do NOT run Cucumber from a task.** Run the targeted commands each task names. The full-suite gates — including the inherited Cucumber contract — are run once by the controller, at the end. Never background a test run.
- **The scheduled race path must not change behaviour.** `GameRun#place_of`, `#finished_teams`, `#results_visible?` and `GameEntry` stay exactly as they are; commercial standings are a separate method. The inherited Cucumber contract (228 scenarios / 2325 steps) is the gate for this.
- **`AccessPass#spent?` is derived, never stored.** No `spent_at`/`consumed_at` column. See the spec, §3 and programme P4.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `db/migrate/20260818110000_add_visibility_to_games.rb` | Create: `games.visibility` + backfill | 1 |
| `app/models/game.rb` | Modify: visibility predicates, shims, `visible` scope, `count_by_status` | 1, 2, 3 |
| `spec/models/game/visibility_spec.rb` | Create | 1 |
| `db/migrate/20260818120000_remove_is_draft_from_games.rb` | Create: drop the old column | 2 |
| `app/views/games/{new,edit}.html.erb` | Modify: checkbox binds `visibility` | 2 |
| `app/controllers/games_controller.rb` | Modify: permit list, `start_test`, `finish_test` | 2 |
| `db/migrate/20260818130000_add_access_mode_to_games.rb` | Create | 3 |
| `spec/models/game/status_spec.rb` | Modify: the `:available` rung | 3 |
| `db/migrate/20260818140000_create_access_passes.rb` | Create | 4 |
| `app/models/access_pass.rb` | Create: the entitlement, `spent?`/`live?`, selection scope | 4 |
| `spec/models/access_pass/spent_spec.rb` | Create | 4 |
| `db/migrate/20260818150000_add_paused_seconds_to_game_passings.rb` | Create: `paused_seconds` | 5 |
| `app/models/game.rb` (`#resume!`) | Modify: widen to `game_passings.in_progress`, accumulate pause | 5 |
| `app/controllers/game_passings_controller.rb` | Modify: resolution + two filters | 6 |
| `db/migrate/20260818160000_add_game_passing_to_logs.rb` | Create | 7 |
| `app/models/log.rb` | Modify: `backfill_passing_ids!` | 7 |
| `app/controllers/logs_controller.rb` | Modify: attempt-scoped path | 7 |
| `app/models/game_passing.rb` | Modify: `#duration` | 8 |
| `app/views/games/_pass_standings.html.erb` | Create | 8 |
| `app/controllers/access_passes_controller.rb` | Create: issue / revoke | 9 |
| `app/controllers/concerns/security_filters.rb` | Modify: the operator clause | 10 |
| `app/controllers/concerns/admin_audit.rb` | Modify: widen `acting_as_operator?` | 10 |

**Phase 1 is Tasks 1–2** (the visibility rename — no commercial concept exists yet). **Phase 2 is Tasks 3–10.** The phases fail differently: a bad visibility migration leaks a draft to the public catalog; a bad entitlement change breaks one team's play screen. Do not interleave them.

---

## Task 1: `games.visibility`, with compatibility shims

**Files:**
- Create: `db/migrate/20260818110000_add_visibility_to_games.rb`
- Modify: `db/schema.rb` (regenerated by the migration, never hand-edited)
- Modify: `app/models/game.rb` — `draft?` (`:127`), `scope :non_drafts` (`:71`), `scope :visible` (`:115`), `count_by_status` (`:366`)
- Test: `spec/models/game/visibility_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `games.visibility` (string, `default: "draft", null: false`, values `draft`/`listed`); `Game::VISIBILITIES`; `Game#draft?` → Boolean; `Game#listed?` → Boolean; temporary shims `Game#is_draft` / `Game#is_draft=` that read and write `visibility`. Task 2 removes the shims; Tasks 3–10 use `draft?`/`listed?`.

**Why shims.** Fifteen files write or read `is_draft`: both author forms, the permit list, `start_test`/`finish_test`, and `create_game` in the spec fixtures. Keeping the old name working for one commit lets the column land with a green suite instead of a coordinated fifteen-file edit. Task 2 removes them in the same commit that drops the column.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game/visibility_spec.rb`:

```ruby
require "rails_helper"

describe Game do
  describe "#visibility" do
    it "defaults a new game to draft" do
      expect(Game.new.visibility).to eq("draft")
    end

    it "refuses a value outside the enum" do
      game = create_game
      game.visibility = "hidden"
      expect(game).not_to be_valid
      expect(game.errors[:visibility]).to be_present
    end

    it "reports draft? from the column" do
      game = create_game
      game.update!(:visibility => "draft")
      expect(game.reload.draft?).to be true
      expect(game.listed?).to be false
    end

    it "reports listed? from the column" do
      game = create_game
      game.update!(:visibility => "listed")
      expect(game.reload.listed?).to be true
      expect(game.draft?).to be false
    end
  end

  # Removed in the next task, together with the is_draft column. Covered while
  # they exist because the whole suite depends on them for one commit.
  describe "the temporary is_draft shims" do
    it "reads draft-ness through the new column" do
      game = create_game
      game.update!(:visibility => "listed")
      expect(game.reload.is_draft).to be false
    end

    it "writes the new column when assigned true" do
      game = create_game
      game.is_draft = true
      expect(game.visibility).to eq("draft")
    end

    it "writes the new column when assigned false" do
      game = create_game
      game.is_draft = false
      expect(game.visibility).to eq("listed")
    end

    # The author form posts strings, not booleans.
    it "casts the string a checkbox posts" do
      game = create_game
      game.is_draft = "0"
      expect(game.visibility).to eq("listed")
      game.is_draft = "1"
      expect(game.visibility).to eq("draft")
    end
  end

  describe ".visible" do
    it "excludes a draft" do
      game = create_game(:is_draft => true)
      expect(Game.visible).not_to include(game)
    end

    it "includes a listed game" do
      game = create_game(:is_draft => false)
      expect(Game.visible).to include(game)
    end

    # Orthogonal to visibility, and deliberately still its own column --
    # see the design, B2a.
    it "excludes a listed game that has been withdrawn" do
      game = create_game(:is_draft => false)
      game.withdraw!
      expect(Game.visible).not_to include(game)
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/models/game/visibility_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'visibility'` / `unknown attribute 'visibility'`. If it fails any other way, stop and diagnose.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260818110000_add_visibility_to_games.rb`:

```ruby
# Backfilled in SQL rather than through the model: a data migration that
# instantiates Game would run today's validations against yesterday's rows,
# and this table holds games written before several of them existed.
#
# withdrawn_at is deliberately NOT consulted. Withdrawal is an orthogonal
# fact with its own column -- see the design, B2a.
class AddVisibilityToGames < ActiveRecord::Migration[8.0]
  def up
    add_column :games, :visibility, :string, :default => "draft", :null => false
    execute "UPDATE games SET visibility = CASE WHEN is_draft THEN 'draft' ELSE 'listed' END"
  end

  def down
    remove_column :games, :visibility
  end
end
```

- [ ] **Step 4: Run the migration and rebuild the test database**

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

Confirm `db/schema.rb` gained `t.string "visibility", default: "draft", null: false` inside `create_table "games"` and that its version line reads `2026_08_18_110000`.

- [ ] **Step 5: Add the predicates, the shims and the enum constant**

In `app/models/game.rb`, replace the existing `draft?` (currently `:127`, `self.is_draft`) and add beside it:

```ruby
  VISIBILITIES = %w[draft listed].freeze

  def draft?
    self.visibility == "draft"
  end

  def listed?
    self.visibility == "listed"
  end

  # TEMPORARY, removed in the task that drops the is_draft column. Fifteen
  # files still say is_draft -- both author forms, the permit list,
  # start_test/finish_test and create_game in the spec fixtures -- and keeping
  # the old name working for one commit is what lets the column land with a
  # green suite instead of a coordinated edit across all of them.
  #
  # These override the ActiveRecord attribute methods of the same name, which
  # is the point: the column is still present but no longer authoritative.
  def is_draft
    draft?
  end

  def is_draft=(value)
    self.visibility = ActiveModel::Type::Boolean.new.cast(value) ? "draft" : "listed"
  end
```

Add the validation beside the existing ones (near `:59`):

```ruby
  validates :visibility, :inclusion => { :in => VISIBILITIES }
```

- [ ] **Step 6: Move the SQL readers off `is_draft`**

Three places in `app/models/game.rb` query the column directly and must move, or they will read a value nothing writes any more.

`scope :non_drafts` (`:71`):

```ruby
  scope :non_drafts, -> { where(:visibility => "listed") }
```

`scope :visible` (`:115`) — keep its entire comment block, change only the first clause:

```ruby
  scope :visible, -> {
    non_drafts.where(:withdrawn_at => nil)
              .where.not(:id => GameRun.where(:is_testing => true).select(:game_id))
  }
```

`count_by_status` (`:366`) — two clauses:

```ruby
    published  = live.where(:visibility => "listed")
    ...
      :draft     => live.where(:visibility => "draft").count,
```

- [ ] **Step 7: Run the new spec and confirm it passes**

Run: `bundle exec rspec spec/models/game/visibility_spec.rb`
Expected: 11 examples, 0 failures.

- [ ] **Step 8: Confirm nothing else moved**

Run: `bundle exec rspec spec/models/game spec/requests/games_listing_spec.rb spec/requests/withdrawal_spec.rb spec/requests/draft_past_start_spec.rb`
Expected: 0 failures. `spec/models/game/status_spec.rb` in particular pins the withdrawn-draft precedence and must still pass untouched — that is the check that the shims really are transparent.

- [ ] **Step 9: Commit**

```bash
git add db/migrate/20260818110000_add_visibility_to_games.rb db/schema.rb \
        app/models/game.rb spec/models/game/visibility_spec.rb
git commit -m "Add games.visibility beside is_draft

A named two-value column (draft/listed) replacing the boolean. Landed
with temporary is_draft shims so the fifteen files that still use the
old name keep working for one commit; the next task removes them with
the column.

withdrawn_at is untouched and stays orthogonal: a withdrawn draft is a
real state that spec/models/game/status_spec.rb pins, and folding it in
would leave restore! with nothing to restore to. See the design, B2a.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: remove `is_draft`

**Files:**
- Create: `db/migrate/20260818120000_remove_is_draft_from_games.rb`
- Modify: `app/models/game.rb` — delete the two shims added in Task 1
- Modify: `app/views/games/new.html.erb:67-68`, `app/views/games/edit.html.erb:76-77`
- Modify: `app/controllers/games_controller.rb` — permit list (`:269`), `start_test` (`:111`), `finish_test` (`:222`)
- Modify: `spec/spec_helpers/fixtures_helper.rb` — `build_game`
- Test: the specs listed in Step 6

**Interfaces:**
- Consumes: `Game#draft?`, `Game#listed?`, `games.visibility` from Task 1.
- Produces: `is_draft` no longer exists anywhere. Every later task uses `visibility`, `draft?`, `listed?`.

- [ ] **Step 1: Move the author forms**

`app/views/games/new.html.erb:67-68` and `app/views/games/edit.html.erb:76-77` both read:

```erb
    <%= f.label :is_draft, t("games.form.is_draft") %>
    <%= f.check_box :is_draft %>
```

Replace each with:

```erb
    <%= f.label :visibility, t("games.form.is_draft") %>
    <%= f.check_box :visibility, {}, "draft", "listed" %>
```

The translation key is deliberately left as `games.form.is_draft`: the label text is unchanged in all seven locales, and renaming a key that no reader can tell apart is churn with a seven-file blast radius. The checkbox's checked/unchecked values are what bind it to the enum — ticked means draft, exactly as before.

- [ ] **Step 2: Move the permit list and the test transitions**

`app/controllers/games_controller.rb:269` — replace `:is_draft` with `:visibility` in `game_attributes`. The inclusion validation from Task 1 is what makes this safe against a hand-posted value.

`start_test` (`:111`):

```ruby
    @game.visibility = "listed"
```

`finish_test` (`:222`):

```ruby
    @game.visibility = "draft"
```

**Preserve the behaviour exactly.** `finish_test` sets draft-ness back **unconditionally** — a tested game always returns to draft, whatever it was before. That is deliberate (you rehearse before publishing) and changing it to restore a previous value would silently publish a game when its test ended. Keep both comment blocks above these methods; the sentence in `start_test`'s comment about "sets is_draft to false" should now say `visibility`.

- [ ] **Step 3: Move the spec fixture**

In `spec/spec_helpers/fixtures_helper.rb`, `build_game` builds a `Game` from an options hash and roughly 200 call sites pass `:is_draft => true/false`. Translate at the boundary rather than editing every call site:

```ruby
  def build_game(options = {})
    # Call sites still speak is_draft, which is the older and shorter name and
    # reads well in an example. Translated here so the fixture keeps that
    # vocabulary without the column existing.
    if options.key?(:is_draft)
      options = options.dup
      options[:visibility] = options.delete(:is_draft) ? "draft" : "listed"
    end
    ...unchanged body...
  end
```

Read the existing method before editing and keep its body intact — this inserts a translation at the top, it does not rewrite it.

**Two things this step must get right, both discovered while Task 1 ran:**

1. **Task 1 added `:is_draft => false` to `build_game`'s DEFAULT hash**, because `visibility` defaults to `"draft"` while the old column defaulted to `false` — without it, examples that name no draftness silently began building drafts. That default must now become `:visibility => "listed"`. Leaving `:is_draft => false` there would pass an unknown attribute to `Game.new` the moment the shims are deleted, because the translation above only fires when the CALLER supplied the key.
2. Verify by running an example that names no draftness and asserting the game is listed. `spec/requests/games_listing_spec.rb` is full of them; if it goes red here, the default was lost.

- [ ] **Step 4: Delete the shims and drop the column**

Remove `Game#is_draft` and `Game#is_draft=` (added in Task 1) from `app/models/game.rb`.

Create `db/migrate/20260818120000_remove_is_draft_from_games.rb`:

```ruby
class RemoveIsDraftFromGames < ActiveRecord::Migration[8.0]
  def up
    remove_column :games, :is_draft
  end

  def down
    add_column :games, :is_draft, :boolean, :default => false, :null => false
    execute "UPDATE games SET is_draft = CASE WHEN visibility = 'draft' THEN 1 ELSE 0 END"
  end
end
```

Then:

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

- [ ] **Step 5: Confirm no reference survives**

Run: `grep -rn "is_draft" app/ config/ lib/ db/schema.rb`
Expected: **no output**. `spec/` legitimately still contains `:is_draft` at the fixture call sites and in the fixture's own translation — that is Step 3's design. `db/migrate/` retains it in the two migrations, which is correct history.

- [ ] **Step 6: Run the affected specs**

Run: `bundle exec rspec spec/models/game spec/requests/games_listing_spec.rb spec/requests/withdrawal_spec.rb spec/requests/draft_past_start_spec.rb spec/requests/game_creation_spec.rb spec/controllers`
Expected: 0 failures.

If `spec/requests/game_creation_spec.rb` does not exist under that name, run `ls spec/requests | grep -i game` and include the creation/editing request specs you find; do not skip this step.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Drop games.is_draft in favour of visibility

Author forms bind the same checkbox to the enum (ticked = draft), the
permit list takes :visibility, and start_test/finish_test set it
explicitly -- finish_test still unconditionally, which is deliberate:
a tested game always returns to draft.

The spec fixture keeps the is_draft vocabulary at its ~200 call sites
and translates once in build_game.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `games.access_mode` and the `:available` status

**Files:**
- Create: `db/migrate/20260818130000_add_access_mode_to_games.rb`
- Modify: `app/models/game.rb` — `ACCESS_MODES`, `#pass_required?`, `#status` (`:345`), `.count_by_status` (`:366`)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/models/game/access_mode_spec.rb` (create), `spec/models/game/status_spec.rb` (modify)

**Interfaces:**
- Consumes: `Game#visibility` from Tasks 1–2.
- Produces: `games.access_mode` (string, `default: "scheduled", null: false`, values `scheduled`/`pass_required`); `Game::ACCESS_MODES`; `Game#pass_required?` → Boolean; `Game#status` may return `:available`; `Game.count_by_status` gains an `:available` key. Tasks 6, 8, 9 and 10 all branch on `pass_required?`.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game/access_mode_spec.rb`:

```ruby
require "rails_helper"

describe Game do
  it "defaults to the scheduled mode" do
    expect(Game.new.access_mode).to eq("scheduled")
    expect(Game.new.pass_required?).to be false
  end

  it "refuses a value outside the enum" do
    game = create_game
    game.access_mode = "invitation"
    expect(game).not_to be_valid
    expect(game.errors[:access_mode]).to be_present
  end

  it "reports pass_required? from the column" do
    game = create_game
    game.update!(:access_mode => "pass_required")
    expect(game.reload.pass_required?).to be true
  end

  describe "#status" do
    # The ladder is positional and the two definitions of it -- this method
    # and count_by_status -- must agree. See the design, §7.
    it "reports :available for a listed gated game" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      expect(game.status).to eq(:available)
    end

    it "still reports :draft for a gated game that is not published" do
      game = create_game(:is_draft => true, :access_mode => "pass_required")
      expect(game.status).to eq(:draft)
    end

    it "still reports :withdrawn for a gated game that was withdrawn" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      game.withdraw!
      expect(game.status).to eq(:withdrawn)
    end

    it "reports :finished for a gated game the author has closed" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      game.finish_game!
      expect(game.reload.status).to eq(:finished)
    end

    it "leaves a scheduled game's status untouched" do
      game = create_game(:is_draft => false)
      expect(game.status).to eq(:scheduled)
    end
  end

  describe ".count_by_status" do
    # If this and #status disagree, the operator dashboard and the catalog
    # label the same game differently -- the exact failure the design warns
    # about, and one this codebase has shipped before.
    it "counts a listed gated game as available, not scheduled" do
      create_game(:is_draft => false, :access_mode => "pass_required")
      counts = Game.count_by_status
      expect(counts[:available]).to eq(1)
      expect(counts[:scheduled]).to eq(0)
    end

    it "agrees with #status for every game it counts" do
      create_game(:is_draft => false, :access_mode => "pass_required")
      create_game(:is_draft => false)
      create_game(:is_draft => true)

      counts = Game.count_by_status
      Game.find_each do |game|
        expect(counts[game.status]).to be >= 1
      end
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/models/game/access_mode_spec.rb`
Expected: FAIL — `unknown attribute 'access_mode'`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260818130000_add_access_mode_to_games.rb`:

```ruby
class AddAccessModeToGames < ActiveRecord::Migration[8.0]
  def change
    add_column :games, :access_mode, :string, :default => "scheduled", :null => false
  end
end
```

No backfill: the default is correct for every existing game.

Then `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 4: Add the enum, the predicate and the status rung**

In `app/models/game.rb`, beside `VISIBILITIES`:

```ruby
  ACCESS_MODES = %w[scheduled pass_required].freeze

  validates :access_mode, :inclusion => { :in => ACCESS_MODES }

  def pass_required?
    self.access_mode == "pass_required"
  end
```

`#status` (`:345`) gains one rung. **Keep the existing comment**, and place `:available` after `:finished` and before `:running`:

```ruby
  def status
    return :withdrawn if withdrawn?
    return :draft     if draft?
    return :finished  if author_finished?
    # A gated game is never "scheduled": it has no start date to wait for and
    # no cohort to wait with. Placed after :finished so an operator who closes
    # a commercial game still sees it reported as finished, and before
    # :running so the schedule rungs below stay purely about scheduled games.
    return :available if pass_required?
    return :running   if started?
    :scheduled
  end
```

- [ ] **Step 5: Add the matching SQL bucket**

`Game.count_by_status` (`:366`) must gain the same rung in the same position, or the dashboard and the catalog disagree. Inside the returned hash, between `:finished` and `:running`:

```ruby
      :available => unfinished.where(:access_mode => "pass_required").count,
```

and both schedule buckets must now exclude gated games, so they keep summing to the total:

```ruby
      :running   => unfinished.where(:access_mode => "scheduled")
                              .where("game_runs.starts_at IS NOT NULL")
                              .where("game_runs.starts_at < ?", now).count,
      :scheduled => unfinished.where(:access_mode => "scheduled")
                              .where("game_runs.starts_at IS NULL OR game_runs.starts_at >= ?", now).count
```

- [ ] **Step 6: Add the status label to all seven locales**

The label lives beside the existing `withdrawn`/`draft`/`finished`/`running`/`scheduled` keys. Find every block that carries them — `grep -n 'scheduled:' config/locales/ru.yml` shows more than one, and **each block that has all five gets the sixth**:

| Locale | value |
|---|---|
| `ru` | `available: "Доступна"` |
| `en` | `available: "Available"` |
| `uk` | `available: "Доступна"` |
| `ka` | `available: "ხელმისაწვდომია"` |
| `tr` | `available: "Erişilebilir"` |
| `be` | `available: "Даступная"` |
| `pl` | `available: "Dostępna"` |

Match the indentation of the sibling `scheduled:` line exactly in each file.

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/models/game/access_mode_spec.rb spec/models/game/status_spec.rb spec/i18n_spec.rb`
Expected: 0 failures. `status_spec.rb` must pass **without modification** — every existing example is about scheduled games, and the new rung is behind `pass_required?`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add games.access_mode and the :available status

A gated game has no start date to wait for and no cohort to wait with,
so it is never :scheduled. The rung is added to BOTH definitions of the
ladder -- Game#status and the SQL in count_by_status -- and the two
schedule buckets now exclude gated games so the columns still sum to
the total. Those two disagreeing is a failure this codebase has shipped
before.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `AccessPass`

**Files:**
- Create: `db/migrate/20260818140000_create_access_passes.rb`
- Create: `app/models/access_pass.rb`
- Modify: `app/models/game.rb`, `app/models/team.rb` — `has_many :access_passes`
- Modify: `spec/spec_helpers/fixtures_helper.rb` — `create_access_pass`
- Test: `spec/models/access_pass/spent_spec.rb`

**Interfaces:**
- Consumes: `Game#pass_required?` from Task 3.
- Produces: table `access_passes` (`game_id`, `team_id`, `source`, `issued_by_id`, `revoked_at`, timestamps); `game_passings.access_pass_id` (nullable, partial-unique) and `GamePassing#access_pass`; `AccessPass#revoked?`, `#spent?`, `#live?`; `AccessPass.next_for(game, team)` → the oldest live pass or nil; `AccessPass::SOURCES`; fixture `create_access_pass(:game =>, :team =>)`. Tasks 5, 6, 8 and 9 all use these.

**The `spent?` reduction.** A pass is spent when the **team** ended the attempt. `GamePassing#exit!` sets `finished_at` as well as `status`, and `end!` (the operator closing a game) sets `status` without `finished_at` — so "completed or exited" is exactly "`finished_at` is present". One column separates team-caused endings from operator-caused ones. The predicate is one expression; the *rule* it encodes is not, which is why the spec below asserts every state.

- [ ] **Step 1: Write the failing test**

Create `spec/models/access_pass/spent_spec.rb`:

```ruby
require "rails_helper"

describe AccessPass do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required"); g }
  let(:team)  { create_team }
  let(:pass)  { create_access_pass(:game => game, :team => team) }

  def attempt_for(pass)
    create_game_passing(:game => pass.game, :team => pass.team, :level => level,
                        :game_run => nil, :access_pass => pass)
  end

  describe "#spent?" do
    it "is false with no attempt yet" do
      expect(pass.spent?).to be false
      expect(pass.live?).to be true
    end

    it "is false while the attempt is in progress" do
      attempt_for(pass)
      expect(pass.reload.spent?).to be false
    end

    it "is true once the team completes the course" do
      attempt = attempt_for(pass)
      attempt.update!(:finished_at => Time.now)
      expect(pass.reload.spent?).to be true
    end

    it "is true once the team quits" do
      attempt = attempt_for(pass)
      attempt.exit!
      expect(pass.reload.spent?).to be true
    end

    # P3: who ended it decides who pays. end! is the operator closing the
    # game, and it leaves finished_at nil -- the customer did not get their
    # run, so the pass is not spent.
    it "is FALSE when an operator ends the game" do
      attempt = attempt_for(pass)
      attempt.end!
      expect(attempt.reload.status).to eq("ended")
      expect(attempt.finished_at).to be_nil
      expect(pass.reload.spent?).to be false
    end

    it "becomes unspent again when an operator reinstates the attempt" do
      attempt = attempt_for(pass)
      attempt.exit!
      expect(pass.reload.spent?).to be true

      attempt.reinstate!
      expect(pass.reload.spent?).to be false
    end

    it "becomes unspent again when an operator moves the team to a level" do
      attempt = attempt_for(pass)
      attempt.update!(:finished_at => Time.now)
      attempt.move_to_level!(level)
      expect(pass.reload.spent?).to be false
    end
  end

  describe "#live?" do
    it "is false once revoked, even with no attempt" do
      pass.update!(:revoked_at => Time.now)
      expect(pass.revoked?).to be true
      expect(pass.live?).to be false
    end
  end

  describe ".next_for" do
    it "is nil when the team holds none" do
      expect(AccessPass.next_for(game, team)).to be_nil
    end

    it "returns the only live pass" do
      expect(AccessPass.next_for(game, pass.team)).to eq(pass)
    end

    it "returns the OLDEST live pass when the team holds several" do
      older = pass
      newer = create_access_pass(:game => game, :team => team)
      newer.update_column(:created_at, older.created_at + 1.hour)

      expect(AccessPass.next_for(game, team)).to eq(older)
    end

    it "skips a spent pass and returns the next one" do
      spent = pass
      attempt_for(spent).update!(:finished_at => Time.now)
      nextone = create_access_pass(:game => game, :team => team)

      expect(AccessPass.next_for(game, team)).to eq(nextone)
    end

    it "skips a revoked pass" do
      pass.update!(:revoked_at => Time.now)
      expect(AccessPass.next_for(game, team)).to be_nil
    end

    it "does not return another game's pass" do
      other = create_level.game
      other.update!(:access_mode => "pass_required")
      create_access_pass(:game => other, :team => team)

      expect(AccessPass.next_for(game, team)).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/models/access_pass/spent_spec.rb`
Expected: FAIL — `NameError: uninitialized constant AccessPass`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260818140000_create_access_passes.rb`:

```ruby
class CreateAccessPasses < ActiveRecord::Migration[8.0]
  def change
    create_table :access_passes do |t|
      t.integer  :game_id,      :null => false
      t.integer  :team_id,      :null => false
      t.string   :source,       :null => false
      t.integer  :issued_by_id
      t.datetime :revoked_at
      t.timestamps
    end

    # Deliberately NOT unique: a team may hold several passes for one game,
    # consumed oldest first. See the design, B6 -- liveness is derived from
    # the attempt, so no index could enforce "one live pass" anyway.
    add_index :access_passes, [ :game_id, :team_id ]

    # The 1:1 binding lives in the same migration as the table it binds,
    # because AccessPass#spent? reads through it -- a pass model without this
    # column has no testable behaviour at all.
    #
    # Written explicitly rather than leaning on the existing
    # (team_id, game_run_id) index, which stops constraining commercial rows
    # only because SQL compares NULLs as distinct -- true, but implicit.
    add_column :game_passings, :access_pass_id, :integer
    add_index  :game_passings, :access_pass_id,
               :unique => true, :where => "access_pass_id IS NOT NULL"
  end
end
```

Then `bin/rails db:migrate && bin/rails db:test:prepare`.

Add the inverse association in `app/models/game_passing.rb`, beside `belongs_to :game_run` (`:67`):

```ruby
  belongs_to :access_pass, :optional => true
```

- [ ] **Step 4: Write the model**

Create `app/models/access_pass.rb`:

```ruby
# -*- encoding : utf-8 -*-
# One team's entitlement to one full run of one game.
#
# Both foreign keys are required: a pass is always somebody's. An unredeemed
# access code is NOT a pass -- in sub-project C it is a row in a separate
# table holding a digest, and redeeming it CREATES a pass. That is what keeps
# team_id NOT NULL here forever.
class AccessPass < ApplicationRecord
  SOURCES = %w[operator_invite].freeze

  belongs_to :game
  belongs_to :team
  belongs_to :issued_by, :class_name => "User", :optional => true

  # The 1:1 binding that makes #spent? derivable. game_passings.access_pass_id
  # carries a partial unique index, so this can never find two.
  has_one :attempt, :class_name => "GamePassing", :foreign_key => "access_pass_id"

  validates :source, :inclusion => { :in => SOURCES }
  validate  :game_is_gated, :on => :create

  def revoked?
    self.revoked_at.present?
  end

  # DERIVED, never stored -- see the programme design, P4.
  #
  # The rule is "the TEAM ended the attempt": completing the course spends the
  # pass, quitting spends it, an operator closing the game does not. That rule
  # reduces to one column because GamePassing#exit! sets finished_at as well as
  # the status, while #end! sets status "ended" and leaves finished_at nil.
  #
  # finished_at.present? is today's ENCODING of the rule, not the rule itself.
  # spec/models/access_pass/spent_spec.rb asserts every state, including both
  # operator cases, so a future change to what end! writes fails a test rather
  # than silently spending customers' passes.
  #
  # It also means reinstate! and move_to_level! un-spend a pass for free: both
  # clear finished_at, and there is no second attempt left to redeem because
  # the pass stays bound to this one.
  def spent?
    attempt.present? && attempt.finished_at.present?
  end

  def live?
    !revoked? && !spent?
  end

  # The pass an attempt should consume: oldest first, so a team granted three
  # passes uses them in the order they were issued.
  #
  # Loaded and filtered in Ruby rather than expressed in SQL: liveness depends
  # on the attempt's finished_at through a LEFT JOIN, a team holds a handful of
  # passes at most, and a SQL form would have to restate the encoding above in
  # a second place. Preloads the attempt so the filter is one query, not N.
  def self.next_for(game, team)
    return nil if team.nil?

    where(:game_id => game.id, :team_id => team.id, :revoked_at => nil)
      .includes(:attempt)
      .order(:created_at)
      .detect(&:live?)
  end

  private

  def game_is_gated
    return if game&.pass_required?

    errors.add(:game, :not_gated)
  end
end
```

- [ ] **Step 5: Wire the associations and the fixture**

In `app/models/game.rb`, beside the other `has_many`s:

```ruby
  has_many :access_passes, :dependent => :destroy
```

In `app/models/team.rb`, beside `has_many :game_passings`:

```ruby
  has_many :access_passes
```

**Not** `dependent: :destroy` on `Team`: `Team#deletable?` already refuses to delete a team that holds history, and a silent cascade would destroy purchase records. Add `access_passes.any?` to that predicate's refusals if it reads a list of associations — read the method before deciding, and say in your report which you found.

In `spec/spec_helpers/fixtures_helper.rb`, beside `create_game_entry`:

```ruby
  def create_access_pass(options = {})
    game = options[:game] || create_game(:is_draft => false, :access_mode => "pass_required")

    AccessPass.create!({
      :game   => game,
      :team   => create_team,
      :source => "operator_invite"
    }.merge(options))
  end
```

- [ ] **Step 6: Add the validation message to all seven locales**

`AccessPass` validates that its game is gated. The message needs both halves — a noun under `activerecord.attributes.access_pass.game`, and a predicate under `activerecord.errors.models.access_pass.attributes.game.not_gated` — because `ApplicationHelper#error_messages_for` renders `"%{attribute} %{message}"`, and without the noun the raw English column name is printed. In Russian, Ukrainian, Belarusian and Polish the predicate must agree in gender with its own noun (`Игра` is feminine).

| Locale | attribute (`game`) | message (`not_gated`) |
|---|---|---|
| `ru` | `Игра` | `не продаётся по доступу` |
| `en` | `Game` | `is not sold by access pass` |
| `uk` | `Гра` | `не продається за доступом` |
| `ka` | `თამაში` | `არ იყიდება წვდომით` |
| `tr` | `Oyun` | `erişim ile satılmıyor` |
| `be` | `Гульня` | `не прадаецца па доступе` |
| `pl` | `Gra` | `nie jest sprzedawana z dostępem` |

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/models/access_pass spec/models/game_passing spec/i18n_spec.rb`
Expected: 0 failures. This task is self-contained — the binding column it needs is added in Step 3 below.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add the AccessPass entitlement

One team's right to one full run. Both foreign keys required: a pass is
always somebody's, and an unredeemed code (sub-project C) is a separate
row that CREATES a pass rather than being one.

spent? is derived from the attempt and never stored. It reduces to
finished_at.present? because exit! sets finished_at while end! does
not -- so one column separates team-caused endings from operator-caused
ones, and reinstate!/move_to_level! un-spend a pass for free.

next_for returns the oldest live pass; the index on (game_id, team_id)
is deliberately not unique.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: the attempt's two new columns, and the pause fix

**Files:**
- Create: `db/migrate/20260818150000_add_paused_seconds_to_game_passings.rb`
- Modify: `app/models/game.rb` — `#resume!` (`:209`)
- Test: `spec/models/game/pause_resume_spec.rb` (create or extend if one exists)

**Interfaces:**
- Consumes: `AccessPass` from Task 4.
- Produces: `game_passings.paused_seconds` (integer, `default: 0, null: false`), accumulated by `Game#resume!`. Task 8 reads it for duration.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game/pause_resume_spec.rb` (if a pause/resume spec already exists under `spec/models/game/`, add these examples to it instead — run `ls spec/models/game` first and say in your report which you did):

```ruby
require "rails_helper"

describe Game do
  describe "#resume!" do
    let(:level) { create_level }
    let(:game)  { level.game }

    it "shifts the level clock of a runless commercial attempt" do
      game.update!(:access_mode => "pass_required", :visibility => "listed")
      pass    = create_access_pass(:game => game)
      attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                    :game_run => nil, :access_pass => pass)
      entered = attempt.current_level_entered_at

      game.pause!
      # Pretend the pause lasted a while.
      game.current_run.update_column(:paused_at, 10.minutes.ago)
      game.reload.resume!

      expect(attempt.reload.current_level_entered_at).to be > entered
    end

    it "accumulates the held time on the attempt" do
      game.update!(:access_mode => "pass_required", :visibility => "listed")
      pass    = create_access_pass(:game => game)
      attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                    :game_run => nil, :access_pass => pass)

      game.pause!
      game.current_run.update_column(:paused_at, 10.minutes.ago)
      game.reload.resume!

      expect(attempt.reload.paused_seconds).to be_within(5).of(600)
    end

    it "still shifts a scheduled run's passings" do
      passing = create_game_passing(:game => game, :level => level)
      entered = passing.current_level_entered_at

      game.pause!
      game.current_run.update_column(:paused_at, 10.minutes.ago)
      game.reload.resume!

      expect(passing.reload.current_level_entered_at).to be > entered
    end

    # end! sets status "ended" WITHOUT finished_at, so the old
    # `where(finished_at: nil)` shifted a clock this passing does not have.
    it "does not shift a passing an operator has already ended" do
      passing = create_game_passing(:game => game, :level => level)
      passing.end!
      entered = passing.reload.current_level_entered_at

      game.pause!
      game.current_run.update_column(:paused_at, 10.minutes.ago)
      game.reload.resume!

      expect(passing.reload.current_level_entered_at).to eq(entered)
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/models/game/pause_resume_spec.rb`
Expected: FAIL — `unknown attribute 'paused_seconds'` on the accumulate example, the runless example failing because `resume!` skips an attempt with no run, and the fourth failing because the ended passing's clock **was** shifted.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260818150000_add_paused_seconds_to_game_passings.rb`:

```ruby
class AddPausedSecondsToGamePassings < ActiveRecord::Migration[8.0]
  def change
    add_column :game_passings, :paused_seconds, :integer, :default => 0, :null => false
  end
end
```

Then `bin/rails db:migrate && bin/rails db:test:prepare`.

`game_passings.access_pass_id` and `belongs_to :access_pass` already exist — Task 4 added them, because a pass model whose binding column is missing has no testable behaviour.

- [ ] **Step 4: Fix `resume!`**

In `app/models/game.rb:209`, replace the loop body. **Keep the whole comment block above the method** — its reasoning about transactions and `update_column` is unchanged — and add the note below:

```ruby
  def resume!
    raise ArgumentError, "not paused" unless self.paused?

    transaction do
      held = Time.now - self.paused_at
      # THE GAME's passings, not the current run's: a commercial attempt has
      # game_run_id NULL and would be skipped, so its hints would jump forward
      # by the length of the pause. Nothing raises; the team simply finds them
      # spent.
      #
      # in_progress rather than where(finished_at: nil): end! sets status
      # "ended" and leaves finished_at nil, so the old form shifted a clock
      # that an operator-ended passing does not have.
      game_passings.in_progress.find_each do |gp|
        gp.update_column(:current_level_entered_at, gp.current_level_entered_at + held)
        gp.update_column(:paused_seconds, gp.paused_seconds + held.round)
      end
      current_run.update_column(:paused_at, nil)
    end
  end
```

- [ ] **Step 5: Run the specs**

Run: `bundle exec rspec spec/models/game/pause_resume_spec.rb spec/models/game_passing`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Accumulate paused time, and fix resume! for runless attempts

game_passings gains paused_seconds.

resume! shifted hint clocks through current_run.passings, so a runless
commercial attempt was skipped entirely and its hints would jump
forward by the length of the pause -- silently. It now walks the game's
passings, and uses in_progress rather than finished_at IS NULL, which
also stops it shifting a clock that operator-ended passings do not have.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: play-path resolution

**Files:**
- Modify: `app/controllers/game_passings_controller.rb` — `find_or_create_game_passing` (`:525`), `may_start_passing?` (`:548`), `ensure_game_is_started` (`:625`), `ensure_team_not_exited` (`:655`)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` — `errors.no_access_pass`
- Test: `spec/requests/gated_play_spec.rb`

**Interfaces:**
- Consumes: `Game#pass_required?` (Task 3), `AccessPass.next_for` (Task 4), `game_passings.access_pass_id` (Task 5).
- Produces: a working play path for gated games. Task 8 reads the attempts it creates.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/gated_play_spec.rb`:

```ruby
require "rails_helper"

describe "playing a gated game", type: :request do
  let(:level)  { create_level }
  let(:game)   { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }
  let(:captain) { create_user }
  let(:team)   { create_team(:captain => captain) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses a team with no pass" do
    team
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
    expect(GamePassing.where(:team_id => team.id)).to be_empty
  end

  it "creates a runless attempt bound to the pass" do
    pass = create_access_pass(:game => game, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    attempt = GamePassing.find_by(:team_id => team.id)
    expect(attempt.game_run_id).to be_nil
    expect(attempt.access_pass_id).to eq(pass.id)
    expect(attempt.current_level_id).to eq(level.id)
  end

  it "serves the same attempt on a second visit rather than making another" do
    create_access_pass(:game => game, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)
    expect { get show_current_level_path(:game_id => game.id) }
      .not_to change { GamePassing.count }
  end

  it "consumes the second pass after the first attempt is completed" do
    first = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    GamePassing.find_by(:access_pass_id => first.id).update!(:finished_at => Time.now)

    second = create_access_pass(:game => game, :team => team)
    get show_current_level_path(:game_id => game.id)

    expect(GamePassing.where(:team_id => team.id).count).to eq(2)
    expect(GamePassing.find_by(:access_pass_id => second.id)).to be_present
  end

  it "refuses a team whose only pass was spent by quitting" do
    pass = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    GamePassing.find_by(:access_pass_id => pass.id).exit!

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
  end

  it "lets a team that quit start again on a replacement pass" do
    first = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    GamePassing.find_by(:access_pass_id => first.id).exit!

    create_access_pass(:game => game, :team => team)
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(GamePassing.where(:team_id => team.id).count).to eq(2)
  end

  it "refuses a gated game that is still a draft" do
    game.update!(:visibility => "draft")
    create_access_pass(:game => game.reload, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not require a start date" do
    create_access_pass(:game => game, :team => team)
    game.current_run.update_column(:starts_at, nil)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
  end
end
```

If `create_access_pass` refuses because the game is not yet gated when the fixture runs, note the ordering: `game` must be materialised (and thus updated) before the pass is created. The `let(:game)` above does that on first reference.

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/requests/gated_play_spec.rb`
Expected: FAIL — most examples 401 through `ensure_game_is_started`, because a gated game has no start date.

- [ ] **Step 3: Teach the started-guard about gated games**

`app/controllers/game_passings_controller.rb:625`:

```ruby
  # A gated game has no start date to wait for and no cohort to wait with, so
  # "has it started?" is not a question about it. What must still be refused is
  # a game the author has not published: otherwise unfinished work is playable
  # by anyone holding an invitation.
  def ensure_game_is_started
    return if @game.is_testing?
    return if @game.pass_required? && !@game.draft?

    raise Authentication::Unauthorized, t("game.not_started") unless viewing_a_started_run?
  end
```

- [ ] **Step 4: Rewrite the resolution**

Replace `find_or_create_game_passing` (`:525`). **Keep the entire comment block above it** — its two numbered points about serving an existing passing and refusing the nil-team case still hold — and append the note below:

```ruby
  # Gated games resolve through the entitlement rather than the current run:
  # a commercial attempt has game_run_id NULL, so current_run.passing_for
  # would never find it. The rule that an EXISTING passing is served before
  # any gate runs is preserved for both, and is what lets a spent pass keep
  # its own finished attempt readable.
  def find_or_create_game_passing
    return @game_passing = gated_passing if @game.pass_required?

    @game_passing = @game.current_run.passing_for(@team)
    return @game_passing if @game_passing

    unless may_start_passing?
      raise Authentication::Unauthorized, t("errors.not_registered_for_game")
    end

    @game_passing = GamePassing.create!(team: @team, game: @game,
                                        game_run: @game.current_run,
                                        current_level: @game.levels.first)
  end

  # The team's attempt if one is live, otherwise a new one on their oldest
  # live pass. An attempt whose pass is spent is NOT live -- that is how a
  # team who bought a replacement gets a second attempt rather than being
  # handed the finished one.
  #
  # An operator-ended attempt IS still live (end! leaves finished_at nil, so
  # the pass is unspent), and is served rather than replaced: unfinish! and
  # reinstate! are how such a game comes back, and they resume where the team
  # stopped. A pass never yields two attempts.
  def gated_passing
    raise Authentication::Unauthorized, t("errors.no_access_pass") if @team.nil?

    live = GamePassing.where(:team_id => @team.id, :game_id => @game.id)
                      .where.not(:access_pass_id => nil)
                      .includes(:access_pass)
                      .detect { |gp| !gp.access_pass.spent? }
    return live if live

    pass = AccessPass.next_for(@game, @team)
    raise Authentication::Unauthorized, t("errors.no_access_pass") if pass.nil?

    GamePassing.create!(:team => @team, :game => @game,
                        :game_run => nil, :access_pass => pass,
                        :current_level => @game.levels.first)
  end
```

- [ ] **Step 5: Teach the exited-guard about replacement passes**

`app/controllers/game_passings_controller.rb:655`:

```ruby
  # A team that quit and then bought a replacement must not be locked out by a
  # filter guarding the attempt they paid to replace. On a gated game the
  # resolution above has already handed back a NEW attempt in that case, so an
  # exited passing reaching here means they have no further pass.
  def ensure_team_not_exited
    raise Authentication::Unauthorized, t("errors.team_exited") if @game_passing.exited?
  end
```

Verify by reading: because `gated_passing` skips attempts whose pass is spent, an exited attempt is only returned when no live pass remains — so this method needs **no change**. Confirm that with the two quit examples in Step 1 and say so in your report. If they fail, the resolution in Step 4 is wrong, not this filter.

- [ ] **Step 6: Add the refusal message to all seven locales**

Under `errors:`, beside `not_registered_for_game`:

| Locale | `no_access_pass` |
|---|---|
| `ru` | `"Для этой игры нужен доступ. Обратитесь к организатору."` |
| `en` | `"This game requires access. Contact the organiser."` |
| `uk` | `"Для цієї гри потрібен доступ. Зверніться до організатора."` |
| `ka` | `"ამ თამაშისთვის საჭიროა წვდომა. მიმართეთ ორგანიზატორს."` |
| `tr` | `"Bu oyun için erişim gerekiyor. Düzenleyiciye başvurun."` |
| `be` | `"Для гэтай гульні патрэбны доступ. Звярніцеся да арганізатара."` |
| `pl` | `"Ta gra wymaga dostępu. Skontaktuj się z organizatorem."` |

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/requests/gated_play_spec.rb spec/requests/play_screen_spec.rb spec/models/game_passing spec/i18n_spec.rb`
Expected: 0 failures. If `spec/requests/play_screen_spec.rb` does not exist, run `ls spec/requests | grep -iE "play|passing"` and include what you find — the scheduled path must be proven untouched.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Resolve the play path through the entitlement for gated games

A gated game resolves its attempt from the team's oldest live pass
rather than from current_run, which could never find a runless one.

The existing rule that an existing passing is served before any gate
runs is preserved. An attempt whose pass is spent is not live, which is
what lets a team who quit and bought a replacement get a NEW attempt --
and is why ensure_team_not_exited needs no change.

ensure_game_is_started exempts gated games, which have no start date to
wait for, but still refuses a draft.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `logs.game_passing_id`

**Files:**
- Create: `db/migrate/20260818160000_add_game_passing_to_logs.rb`
- Modify: `app/models/log.rb` — `scope :of_attempt`, `self.backfill_passing_ids!`
- Modify: `app/controllers/game_passings_controller.rb` — `save_log` (`:612`)
- Modify: `app/controllers/logs_controller.rb` — `show_full_log` (`:61`) and its scope helper (`:90`)
- Test: `spec/models/log_backfill_spec.rb`, `spec/requests/gated_log_scope_spec.rb`

**Interfaces:**
- Consumes: attempts from Task 6.
- Produces: `logs.game_passing_id` (nullable, indexed); `Log.of_attempt(passing)`; `Log.backfill_passing_ids!` → `{ :resolved => n }`.

**Why.** Once `game_run_id` is NULL, a commercial attempt's logs are scoped by `(game_id, team_id)` — which cannot tell a team's second pass from its first. With one standings row per attempt (spec B7) that is not acceptable.

- [ ] **Step 1: Write the failing test**

Create `spec/models/log_backfill_spec.rb`:

```ruby
require "rails_helper"

describe Log do
  describe ".backfill_passing_ids!" do
    it "resolves a scheduled log from its run and team" do
      level   = create_level
      passing = create_game_passing(:game => level.game, :level => level)
      log = Log.create!(:game_id => level.game.id, :team_id => passing.team_id,
                        :level_id => level.id, :game_run_id => passing.game_run_id,
                        :time => Time.now, :answer => "x")

      expect(Log.backfill_passing_ids!).to eq(:resolved => 1)
      expect(log.reload.game_passing_id).to eq(passing.id)
    end

    it "is idempotent" do
      level   = create_level
      passing = create_game_passing(:game => level.game, :level => level)
      Log.create!(:game_id => level.game.id, :team_id => passing.team_id,
                  :level_id => level.id, :game_run_id => passing.game_run_id,
                  :time => Time.now, :answer => "x")

      Log.backfill_passing_ids!
      expect(Log.backfill_passing_ids!).to eq(:resolved => 0)
    end

    it "leaves a log it cannot resolve alone" do
      level = create_level
      log = Log.create!(:game_id => level.game.id, :team_id => create_team.id,
                        :level_id => level.id, :time => Time.now, :answer => "x")

      Log.backfill_passing_ids!
      expect(log.reload.game_passing_id).to be_nil
    end
  end

  describe ".of_attempt" do
    it "returns only that attempt's rows" do
      level = create_level
      a = create_game_passing(:game => level.game, :level => level)
      b = create_game_passing(:game => level.game, :level => level)
      mine  = Log.create!(:game_id => level.game.id, :game_passing_id => a.id,
                          :time => Time.now, :answer => "mine")
      Log.create!(:game_id => level.game.id, :game_passing_id => b.id,
                  :time => Time.now, :answer => "theirs")

      expect(Log.of_attempt(a)).to eq([ mine ])
    end
  end
end
```

Create `spec/requests/gated_log_scope_spec.rb`:

```ruby
require "rails_helper"

describe "logs of a gated game", type: :request do
  let(:level)   { create_level }
  let(:game)    { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # The point of the column: two attempts by the SAME team in the SAME game
  # are indistinguishable by (game_id, team_id).
  it "attributes each answer to the attempt that submitted it" do
    first = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    post post_answer_path(:game_id => game.id), :params => { :answer => "wrong-one" }

    attempt_one = GamePassing.find_by(:access_pass_id => first.id)
    attempt_one.update!(:finished_at => Time.now)

    second = create_access_pass(:game => game, :team => team)
    get show_current_level_path(:game_id => game.id)
    post post_answer_path(:game_id => game.id), :params => { :answer => "wrong-two" }
    attempt_two = GamePassing.find_by(:access_pass_id => second.id)

    expect(Log.of_attempt(attempt_one).map(&:answer)).to eq([ "wrong-one" ])
    expect(Log.of_attempt(attempt_two).map(&:answer)).to eq([ "wrong-two" ])
  end
end
```

If the answer-posting route helper differs, read `config/routes.rb` for the `post_answer` route and use the real helper — do not invent one.

- [ ] **Step 2: Run both and confirm they fail for the right reason**

Run: `bundle exec rspec spec/models/log_backfill_spec.rb spec/requests/gated_log_scope_spec.rb`
Expected: FAIL — `unknown attribute 'game_passing_id'` / `undefined method 'backfill_passing_ids!'`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260818160000_add_game_passing_to_logs.rb`:

```ruby
class AddGamePassingToLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :logs, :game_passing_id, :integer
    add_index  :logs, :game_passing_id

    resolved = Log.backfill_passing_ids!
    say "backfilled game_passing_id on #{resolved[:resolved]} log rows"
  end

  def down
    remove_column :logs, :game_passing_id
  end
end
```

Reporting the count is deliberate and copied from `Log.backfill_run_ids!`: a backfill that resolved nothing must not look identical to one that resolved everything.

- [ ] **Step 4: Add the scope and the backfill**

In `app/models/log.rb`, beside `scope :of_run`:

```ruby
  # A log line belongs to one team's one attempt. game_run_id was only ever a
  # proxy for that, and stops being one when a commercial attempt has no run.
  scope :of_attempt, ->(passing) { where(:game_passing_id => passing.id) }
```

and beside `backfill_run_ids!`:

```ruby
  # Idempotent and safe to re-run: only touches rows whose game_passing_id is
  # still NULL. Returns the count, which the migration logs -- see
  # backfill_run_ids! for why that matters.
  #
  # Resolves from (game_run_id, team_id), which is unique by the index on
  # game_passings. A row missing either simply stays NULL rather than being
  # guessed at: an answer attributed to the wrong attempt is worse than one
  # attributed to none.
  def self.backfill_passing_ids!
    resolved = 0

    where(:game_passing_id => nil).where.not(:game_run_id => nil)
                                  .where.not(:team_id => nil).find_each do |log|
      passing = GamePassing.find_by(:game_run_id => log.game_run_id, :team_id => log.team_id)
      next if passing.nil?

      log.update_column(:game_passing_id, passing.id)
      resolved += 1
    end

    { :resolved => resolved }
  end
```

- [ ] **Step 5: Write the column**

In `app/controllers/game_passings_controller.rb`, `save_log` (`:612`) builds a `Log`. Add `game_passing_id: @game_passing.id` to that `Log.create` call, alongside the existing `game_run` argument. Read the method first and add the argument to the existing hash — do not restructure it.

- [ ] **Step 6: Make the player's full log attempt-scoped for gated games**

`LogsController#show_full_log` (`:61`) and the scope helper at `:90` filter by `game_passings.game_run_id`. For a gated game that join matches nothing.

Read both methods, then make the scope branch: when `@game.pass_required?`, scope the rows by the requesting team's attempt via `Log.of_attempt` instead of by run. `find_run` (`:109`) and `count_the_run` (`:135`) must tolerate a gated game, which has no meaningful run — the simplest correct form is to skip the run lookup entirely for gated games and drive everything from the attempt.

The behaviour required is exactly what `spec/requests/gated_log_scope_spec.rb` asserts plus this: a gated game's full log must show the requesting team's own attempt and no other team's. Add that example yourself in the same file, following the shape of the existing `spec/requests/full_log_scope_spec.rb`, which is the established pattern for this screen — read it first.

**Out of scope, deliberately:** the author-facing live channel and per-level log screens stay scheduled-only in this sub-project. They are operator tooling for a race in progress, and a gated game's equivalent is the attempt list in Task 9. Say so in your report rather than extending them.

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/models/log_backfill_spec.rb spec/requests/gated_log_scope_spec.rb spec/requests/full_log_scope_spec.rb spec/models/log_spec.rb`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Attribute log lines to the attempt that produced them

Once game_run_id is NULL, (game_id, team_id) cannot tell a team's
second pass from its first -- and with one standings row per attempt
that is not good enough. logs.game_passing_id is what game_run_id was
always a proxy for.

Backfilled from (game_run_id, team_id), reporting its count, and rows
it cannot resolve stay NULL: an answer attributed to the wrong attempt
is worse than one attributed to none.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: duration and standings

**Files:**
- Modify: `app/models/game_passing.rb` — `#duration`
- Modify: `app/models/game.rb` — `#pass_standings`
- Create: `app/views/games/_pass_standings.html.erb`
- Modify: `app/views/games/show.html.erb` — render it
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/models/game/pass_standings_spec.rb`, `spec/requests/gated_standings_spec.rb`

**Interfaces:**
- Consumes: attempts (Task 6), `paused_seconds` (Task 5).
- Produces: `GamePassing#duration` → Integer seconds or nil; `Game#pass_standings` → Array of completed attempts ordered by duration.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game/pass_standings_spec.rb`:

```ruby
require "rails_helper"

describe Game do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }

  def completed_attempt(seconds, paused: 0, penalty: 0)
    pass    = create_access_pass(:game => game)
    started = 3.days.ago
    attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                  :game_run => nil, :access_pass => pass)
    attempt.update_columns(:created_at => started,
                           :finished_at => started + seconds,
                           :paused_seconds => paused,
                           :penalty_seconds => penalty)
    attempt
  end

  describe "GamePassing#duration" do
    it "is finish minus start" do
      expect(completed_attempt(600).duration).to be_within(1).of(600)
    end

    it "subtracts time the game was paused" do
      expect(completed_attempt(600, paused: 120).duration).to be_within(1).of(480)
    end

    it "adds accrued penalties" do
      expect(completed_attempt(600, penalty: 60).duration).to be_within(1).of(660)
    end

    it "is nil for an unfinished attempt" do
      pass = create_access_pass(:game => game)
      attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                    :game_run => nil, :access_pass => pass)
      expect(attempt.duration).to be_nil
    end
  end

  describe "#pass_standings" do
    it "orders by duration, fastest first" do
      slow = completed_attempt(900)
      fast = completed_attempt(300)

      expect(game.pass_standings).to eq([ fast, slow ])
    end

    it "excludes an attempt that is still running" do
      pass = create_access_pass(:game => game)
      create_game_passing(:game => game, :team => pass.team, :level => level,
                          :game_run => nil, :access_pass => pass)

      expect(game.pass_standings).to be_empty
    end

    # exit! sets finished_at, so an abandoned attempt must be excluded by
    # status, not by finished_at alone.
    it "excludes an attempt the team abandoned" do
      attempt = completed_attempt(300)
      attempt.exit!

      expect(game.pass_standings).to be_empty
    end

    # B7: a row is an attempt, not a team.
    it "lists the same team twice when it completed two passes" do
      team = create_team
      a = completed_attempt(300); a.update!(:team => team)
      b = completed_attempt(900); b.update!(:team => team)

      expect(game.pass_standings.map(&:team_id)).to eq([ team.id, team.id ])
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/models/game/pass_standings_spec.rb`
Expected: FAIL — `undefined method 'duration'`.

- [ ] **Step 3: Implement duration**

In `app/models/game_passing.rb`, beside `effective_finished_at` (`:198`):

```ruby
  # What commercial standings rank on. NOT effective_finished_at, which is an
  # absolute timestamp: every pass starts when its own team opens the play
  # screen, so comparing instants would place a team that played in August
  # behind one that played in March however fast it was. GameRun#place_of's
  # comment records that exact defect.
  #
  # paused_seconds is subtracted because an operator pausing the game is not
  # the customer's doing; penalty_seconds is added for the same reason it is
  # added to effective_finished_at.
  def duration
    return nil unless self.finished_at

    (self.finished_at - self.created_at).round - self.paused_seconds.to_i + self.penalty_seconds.to_i
  end
```

In `app/models/game.rb`:

```ruby
  # One row per COMPLETED attempt, fastest first. Completed means the team
  # crossed the line: finished_at set and not exited -- the same pair
  # GamePassing's `completed` scope uses, and the same pair that decides
  # whether a pass was spent.
  #
  # Sorted in Ruby rather than SQL for the same reason GameRun#place_of does:
  # expressing the arithmetic portably across SQLite and PostgreSQL is more
  # trouble than it is worth for a listing of tens of attempts.
  def pass_standings
    game_passings.completed.includes(:team).to_a.sort_by(&:duration)
  end
```

- [ ] **Step 4: Add the standings partial**

Create `app/views/games/_pass_standings.html.erb`:

```erb
<% standings = game.pass_standings %>
<% if standings.any? %>
  <h3><%= t("games.standings.title") %></h3>
  <div class="table-wrap">
  <table class="data">
    <thead>
      <tr>
        <th><%= t("games.standings.place") %></th>
        <th><%= t("games.standings.team") %></th>
        <th><%= t("games.standings.finished_at") %></th>
        <th><%= t("games.standings.duration") %></th>
      </tr>
    </thead>
    <tbody>
      <% standings.each_with_index do |attempt, index| %>
        <tr>
          <td data-label="<%= t("games.standings.place") %>"><%= index + 1 %></td>
          <td data-label="<%= t("games.standings.team") %>"><%= attempt.team&.name %></td>
          <td data-label="<%= t("games.standings.finished_at") %>"><%= l(attempt.finished_at, :format => :long) %></td>
          <td data-label="<%= t("games.standings.duration") %>"><%= distance_of_time_in_words(attempt.duration) %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
  </div>
<% end %>
```

`data-label` attributes are how this app's tables collapse on a phone — `app/views/admin/users/index.html.erb` uses the same convention; match it.

In `app/views/games/show.html.erb`, render it beside the existing teams partial (`:141`):

```erb
<%= render "pass_standings", game: @game if @game.pass_required? %>
```

- [ ] **Step 5: Add the five keys to all seven locales**

Under `games:`, a new `standings:` block:

| Key | ru | en | uk | ka | tr | be | pl |
|---|---|---|---|---|---|---|---|
| `title` | Результаты | Results | Результати | შედეგები | Sonuçlar | Вынікі | Wyniki |
| `place` | Место | Place | Місце | ადგილი | Sıra | Месца | Miejsce |
| `team` | Команда | Team | Команда | გუნდი | Takım | Каманда | Drużyna |
| `finished_at` | Финиш | Finished | Фініш | ფინიში | Bitiş | Фініш | Meta |
| `duration` | Время | Time | Час | დრო | Süre | Час | Czas |

None interpolates a name, so the Turkish agglutination rule does not bite here.

- [ ] **Step 6: Write the request spec and run everything**

Create `spec/requests/gated_standings_spec.rb` asserting that the game page of a gated game renders «Результаты» and the finishing team's name, and that a scheduled game's page does **not** render «Результаты». Follow the sign-in helper shape used in `spec/requests/gated_play_spec.rb`.

Run: `bundle exec rspec spec/models/game/pass_standings_spec.rb spec/requests/gated_standings_spec.rb spec/i18n_spec.rb spec/models/game_run_spec.rb`
Expected: 0 failures. `game_run_spec.rb` is included deliberately: `place_of` must still rank within a run exactly as before.

- [ ] **Step 7: Send `show_results` to the standings for gated games**

The spec's §6 lists `GamePassingsController#show_results` among the run-scoped readers. It resolves
a run through `find_run`/`latest_started_run` and guards on `GameRun#results_visible?`, which is
false for a gated game — so today it answers 401. A gated game's results are the standings on the
game page, so send the visitor there instead of refusing them.

In `app/controllers/game_passings_controller.rb`, at the top of `show_results` (`:163`):

```ruby
  def show_results
    # A gated game has no cohort and no run standings. Its results are the
    # per-attempt standings on the game page -- see the design, B7.
    return redirect_to(game_path(@game)) if @game.pass_required?

    ...existing body unchanged...
  end
```

`ensure_game_is_started` runs before this action and already exempts gated games (Task 6, Step 3),
so the redirect is reachable.

Add to `spec/requests/gated_standings_spec.rb`:

```ruby
  it "redirects the run-results page to the game page" do
    get show_results_path(:game_id => game.id)

    expect(response).to redirect_to(game_path(game))
  end
```

Read `config/routes.rb` for the real `show_results` helper name and use what is there.

Run: `bundle exec rspec spec/requests/gated_standings_spec.rb spec/requests/results_spec.rb`
Expected: 0 failures. If no `results_spec.rb` exists, run `ls spec/requests | grep -i result` and use what you find — the scheduled results page must be proven untouched.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Rank commercial attempts by duration

Standings are per game, across all passes, one row per completed
attempt. They share no code with GameRun#place_of, which ranks on
absolute finish time -- correct within a run, and the documented defect
across cohorts, which is what every commercial pass is.

Duration subtracts paused_seconds: an operator pausing the game is not
the customer's doing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: the operator surface

**Files:**
- Create: `app/controllers/access_passes_controller.rb`
- Create: `app/views/access_passes/index.html.erb`
- Modify: `config/routes.rb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/access_pass_issuing_spec.rb`

**Interfaces:**
- Consumes: `AccessPass` (Task 4), `User#may_operate_commercial?` (sub-project A), `Game#pass_required?` (Task 3).
- Produces: routes `game_access_passes_path(game)`, `game_access_passes_path(game)` POST, `game_access_pass_path(game, pass)` DELETE; audit actions `issue_access_pass` / `revoke_access_pass`.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/access_pass_issuing_spec.rb`:

```ruby
require "rails_helper"

describe "issuing and revoking access passes", type: :request do
  let(:level)      { create_level }
  let(:game)       { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }
  let(:operator)   { u = create_user; u.update!(:is_operator => true); u }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:ordinary)   { create_user }
  let(:team)       { create_team }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary signed-in user" do
    sign_in(ordinary)
    post game_access_passes_path(game), :params => { :team_name => team.name }
    expect(response).to have_http_status(:unauthorized)
    expect(AccessPass.count).to eq(0)
  end

  it "refuses an anonymous visitor" do
    post game_access_passes_path(game), :params => { :team_name => team.name }
    expect(AccessPass.count).to eq(0)
  end

  it "lets an operator issue a pass" do
    sign_in(operator)
    expect { post game_access_passes_path(game), :params => { :team_name => team.name } }
      .to change { AccessPass.count }.by(1)

    pass = AccessPass.last
    expect(pass.team_id).to eq(team.id)
    expect(pass.game_id).to eq(game.id)
    expect(pass.source).to eq("operator_invite")
    expect(pass.issued_by_id).to eq(operator.id)
  end

  it "lets a superadmin issue a pass" do
    sign_in(superadmin)
    expect { post game_access_passes_path(game), :params => { :team_name => team.name } }
      .to change { AccessPass.count }.by(1)
  end

  it "records an audit entry" do
    sign_in(operator)
    expect { post game_access_passes_path(game), :params => { :team_name => team.name } }
      .to change { AdminAction.count }.by(1)
    expect(AdminAction.newest_first.first.action).to eq("issue_access_pass")
  end

  it "reports an unknown team without creating anything" do
    sign_in(operator)
    expect { post game_access_passes_path(game), :params => { :team_name => "no such team" } }
      .not_to change { AccessPass.count }
    expect(response).to redirect_to(game_access_passes_path(game))
  end

  it "refuses to issue on a scheduled game" do
    scheduled = create_level.game
    sign_in(operator)
    post game_access_passes_path(scheduled), :params => { :team_name => team.name }
    expect(AccessPass.count).to eq(0)
  end

  it "revokes an unused pass" do
    pass = create_access_pass(:game => game, :team => team)
    sign_in(operator)

    delete game_access_pass_path(game, pass)

    expect(pass.reload.revoked_at).to be_present
    expect(AdminAction.newest_first.first.action).to eq("revoke_access_pass")
  end

  # B11: a started run is an intervention problem, not a revocation one.
  it "refuses to revoke a pass whose attempt has begun" do
    pass = create_access_pass(:game => game, :team => team)
    create_game_passing(:game => game, :team => team, :level => level,
                        :game_run => nil, :access_pass => pass)
    sign_in(operator)

    delete game_access_pass_path(game, pass)

    expect(pass.reload.revoked_at).to be_nil
  end
end
```

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/requests/access_pass_issuing_spec.rb`
Expected: FAIL — `undefined local variable or method 'game_access_passes_path'`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, nested under the games resource (read the file for the existing shape — this app writes explicit routes, not blanket `resources`):

```ruby
  # Commercial entitlements. Nested under the game because every action is
  # about one game's passes, and the authorization asks about that game.
  resources :games, only: [] do
    resources :access_passes, only: [ :index, :create, :destroy ]
  end
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/access_passes_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
# Issuing and revoking commercial entitlements. Operators and superadmins
# only -- see the operator-role design, D2: an operator's authority is
# scoped to gated games and nothing else.
class AccessPassesController < ApplicationController
  include AdminAudit

  before_action :require_authentication!
  before_action :find_game
  before_action :ensure_commercial_operator
  before_action :ensure_game_is_gated

  def index
    @passes = @game.access_passes.includes(:team, :attempt, :issued_by).order(:created_at)
  end

  def create
    team = Team.find_by(:name => params[:team_name].to_s.strip)

    if team.nil?
      redirect_to game_access_passes_path(@game),
                  :alert => t("access_passes.not_found") and return
    end

    pass = AccessPass.create!(:game => @game, :team => team,
                              :source => "operator_invite",
                              :issued_by => current_user)

    record_admin_action("issue_access_pass", @game, team.name)
    redirect_to game_access_passes_path(@game),
                :notice => t("access_passes.issued_notice", :team => team.name)
  end

  # Refused once the pass has an attempt, and that boundary is what keeps
  # AccessPass#spent? honest: if revocation could kill a live attempt,
  # revoked_at would start competing with the derived state for "may this
  # team play". A started run is an intervention -- see
  # InterventionsController.
  def destroy
    pass = @game.access_passes.find(params[:id])

    if pass.attempt.present?
      redirect_to game_access_passes_path(@game),
                  :alert => t("access_passes.cannot_revoke_started") and return
    end

    pass.update!(:revoked_at => Time.now)
    record_admin_action("revoke_access_pass", @game, pass.team&.name)
    redirect_to game_access_passes_path(@game),
                :notice => t("access_passes.revoked_notice")
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def ensure_commercial_operator
    raise Authentication::Unauthorized, t("errors.must_be_superadmin") unless
      current_user.may_operate_commercial?
  end

  def ensure_game_is_gated
    raise Authentication::Unauthorized, t("errors.must_be_author") unless @game.pass_required?
  end
end
```

Read `app/controllers/admin/users_controller.rb` first and match this app's controller conventions — in particular how `require_authentication!` is included and how `Authentication::Unauthorized` is raised elsewhere.

- [ ] **Step 5: Write the view**

Create `app/views/access_passes/index.html.erb`:

```erb
<h2 class="page-title"><%= t("access_passes.title") %> &mdash; <%= @game.name %></h2>

<%= form_with url: game_access_passes_path(@game), method: :post, local: true do |f| %>
  <p>
    <%= label_tag :team_name, t("access_passes.team_name") %>
    <%= text_field_tag :team_name %>
    <%= submit_tag t("access_passes.submit"), :class => "btn btn--go" %>
  </p>
<% end %>

<div class="table-wrap">
<table class="data">
  <thead>
    <tr>
      <th><%= t("access_passes.team_name") %></th>
      <th><%= t("access_passes.issued") %></th>
      <th><%= t("access_passes.state") %></th>
      <th></th>
    </tr>
  </thead>
  <tbody>
  <% @passes.each do |pass| %>
    <tr>
      <td data-label="<%= t("access_passes.team_name") %>"><%= pass.team&.name %></td>
      <td data-label="<%= t("access_passes.issued") %>"><%= l(pass.created_at, :format => :long) %></td>
      <td data-label="<%= t("access_passes.state") %>">
        <% if pass.revoked? %>
          <%= t("access_passes.state_revoked") %>
        <% elsif pass.spent? %>
          <%= t("access_passes.state_spent") %>
        <% elsif pass.attempt.present? %>
          <%= t("access_passes.state_playing") %>
        <% else %>
          <%= t("access_passes.state_live") %>
        <% end %>
      </td>
      <td>
        <%# Offered only where #destroy would accept: an unstarted, unrevoked
            pass. A started one is an intervention, not a revocation -- B11.

            Deliberately NO confirmation attribute. This app ships neither
            Turbo nor rails-ujs, so data-confirm and data-turbo-confirm are
            both inert; an attribute implying a safety net nobody gets is
            worse than none. %>
        <% if pass.attempt.nil? && !pass.revoked? %>
          <%= button_to t("access_passes.revoke"), game_access_pass_path(@game, pass),
                        :method => :delete, :class => "btn btn--danger" %>
        <% end %>
      </td>
    </tr>
  <% end %>
  </tbody>
</table>
</div>
```

`data-label` attributes are how this app's tables collapse on a phone; `app/views/admin/users/index.html.erb` uses the same convention. Read it before writing this and match the surrounding markup.

Seven further keys are needed for this view, in all seven locales:

| Key | ru | en | uk | ka | tr | be | pl |
|---|---|---|---|---|---|---|---|
| `issued` | Выдан | Issued | Виданий | გაცემული | Verildi | Выдадзены | Wydany |
| `state` | Состояние | State | Стан | მდგომარეობა | Durum | Стан | Stan |
| `state_live` | не использован | unused | не використаний | გამოუყენებელი | kullanılmadı | не выкарыстаны | niewykorzystany |
| `state_playing` | проходится | in progress | проходиться | მიმდინარეობს | devam ediyor | праходзіцца | w trakcie |
| `state_spent` | использован | used | використаний | გამოყენებული | kullanıldı | выкарыстаны | wykorzystany |
| `state_revoked` | отозван | revoked | відкликаний | ჩამორთმეული | geri alındı | адкліканы | odebrany |
| `revoke` | Отозвать | Revoke | Відкликати | ჩამორთმევა | Geri al | Адклікаць | Odbierz |

- [ ] **Step 6: Add the keys to all seven locales**

Under a new `access_passes:` block, plus two audit labels under `admin.audit.index.action`:

| Key | ru | en |
|---|---|---|
| `access_passes.title` | Доступ к игре | Game access |
| `access_passes.team_name` | Название команды | Team name |
| `access_passes.submit` | Выдать доступ | Issue access |
| `access_passes.issued_notice` | Доступ выдан команде «%{team}» | Access issued to “%{team}” |
| `access_passes.revoked_notice` | Доступ отозван | Access revoked |
| `access_passes.not_found` | Команда не найдена | Team not found |
| `access_passes.cannot_revoke_started` | Нельзя отозвать доступ: команда уже начала прохождение | Cannot revoke: the team has already started |
| `admin.audit.index.action.issue_access_pass` | Выдал доступ к игре | Issued game access |
| `admin.audit.index.action.revoke_access_pass` | Отозвал доступ к игре | Revoked game access |

The remaining five locales, in the same order:

- `uk`: Доступ до гри / Назва команди / Видати доступ / Доступ надано команді «%{team}» / Доступ відкликано / Команду не знайдено / Не можна відкликати доступ: команда вже почала проходження / Надав доступ до гри / Відкликав доступ до гри
- `ka`: თამაშის წვდომა / გუნდის სახელი / წვდომის მინიჭება / წვდომა მიენიჭა გუნდს «%{team}» / წვდომა ჩამორთმეულია / გუნდი ვერ მოიძებნა / წვდომის ჩამორთმევა შეუძლებელია: გუნდმა უკვე დაიწყო / მიანიჭა თამაშის წვდომა / ჩამოართვა თამაშის წვდომა
- `tr`: Oyun erişimi / Takım adı / Erişim ver / «%{team}» adlı takıma erişim verildi / Erişim geri alındı / Takım bulunamadı / Erişim geri alınamaz: takım çoktan başladı / Oyun erişimi verdi / Oyun erişimini geri aldı
- `be`: Доступ да гульні / Назва каманды / Выдаць доступ / Доступ выдадзены камандзе «%{team}» / Доступ адкліканы / Каманда не знойдзена / Нельга адклікаць доступ: каманда ўжо пачала праходжанне / Выдаў доступ да гульні / Адклікаў доступ да гульні
- `pl`: Dostęp do gry / Nazwa drużyny / Nadaj dostęp / Nadano dostęp drużynie „%{team}” / Dostęp odebrany / Nie znaleziono drużyny / Nie można odebrać dostępu: drużyna już zaczęła / Nadał dostęp do gry / Odebrał dostęp do gry

**Note the Turkish `issued_notice`:** the suffix lands on `takım` (`«%{team}» adlı takıma`), never on the placeholder — a case suffix cannot attach to a name the operator typed. Verify by rendering with a consonant-final and a vowel-final team name; if only one reads naturally, the template is inflecting around the placeholder.

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/requests/access_pass_issuing_spec.rb spec/requests/admin_audit_spec.rb spec/i18n_spec.rb spec/i18n_audit_actions_spec.rb`
Expected: 0 failures. `spec/i18n_audit_actions_spec.rb` scrapes action names out of the controllers and asserts a translation in **every** available locale, so it will fail loudly if any of the seven is missing an audit label — unlike the `admin.users.*` keys, these are hard-covered.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Let an operator issue and revoke access passes

Nested under the game, gated on may_operate_commercial? and
pass_required?, audited both ways.

Revocation is refused once the pass has an attempt. That boundary is
what keeps spent? honest: if revoking could kill a live attempt,
revoked_at would compete with the derived state for 'may this team
play'. A started run is an intervention.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: the operator's authority

**Files:**
- Modify: `app/controllers/concerns/security_filters.rb` — `ensure_author` (`:31`)
- Modify: `app/controllers/concerns/admin_audit.rb` — `acting_as_operator?`
- Test: `spec/requests/operator_authority_spec.rb`

**Interfaces:**
- Consumes: `User#operator?`, `User#may_operate_commercial?` (sub-project A), `Game#pass_required?` (Task 3).
- Produces: nothing later tasks read. This is the last task.

**This is the change sub-project A specified and deliberately deferred** — see its spec §5 and §6. A called the predicate `commercial?`; the column landed as `access_mode`, so it is `pass_required?`.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/operator_authority_spec.rb`:

```ruby
require "rails_helper"

describe "an operator's authority", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_operator => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def gated_game
    g = create_game(:author => author, :is_draft => false)
    g.update!(:access_mode => "pass_required")
    g
  end

  it "lets an operator edit a gated game they did not author" do
    game = gated_game
    sign_in(operator)

    get edit_game_path(game)

    expect(response).to have_http_status(:ok)
  end

  # D2: the authority is scoped to gated games and nothing else. This is the
  # whole reason the clause is game-conditional rather than a bare widening.
  it "does NOT let an operator edit an ordinary game they did not author" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(operator)

    get edit_game_path(game)

    expect(response).to have_http_status(:unauthorized)
  end

  # ensure_author also gates levels, hints, questions and entries. An operator
  # must not reach a player's public game THROUGH its levels controller.
  it "does NOT let an operator add a level to an ordinary game" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(operator)

    get new_game_level_path(game)

    expect(response).to have_http_status(:unauthorized)
  end

  it "lets an operator add a level to a gated game" do
    game = gated_game
    sign_in(operator)

    get new_game_level_path(game)

    expect(response).to have_http_status(:ok)
  end

  it "audits an operator acting on a gated game they did not author" do
    game = gated_game
    sign_in(operator)

    expect { post withdraw_game_path(game) }.to change { AdminAction.count }.by(1)
    expect(AdminAction.newest_first.first.action).to eq("withdraw")
  end
end
```

Read `config/routes.rb` for the real level and withdraw route helpers before running — use what is there, do not invent helpers.

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `bundle exec rspec spec/requests/operator_authority_spec.rb`
Expected: FAIL — the operator is refused on the gated game (401 where 200 expected), because the clause does not exist yet. The two "does NOT" examples should already pass.

- [ ] **Step 3: Add the authority clause**

`app/controllers/concerns/security_filters.rb:31`. **Keep the entire SECURITY CHOKEPOINT comment** and add to it:

```ruby
  def ensure_author
    return if logged_in? && current_user.superadmin?
    # An operator's authority is scoped to GATED games -- deliberately
    # game-conditional rather than a bare `|| current_user.operator?`. This
    # filter also gates levels, hints, questions and game entries, so the
    # unscoped form would let an operator reach an ordinary player's public
    # game through its levels controller, in a diff that never mentions games.
    return if logged_in? && current_user.operator? && @game&.pass_required?

    raise Authentication::Unauthorized, t("errors.must_be_author") unless logged_in? && current_user.author_of?(@game)
  end
```

`@game&.` with safe navigation, matching `ensure_editing_not_locked` two methods below — evidence that at least one call site reaches these filters with no game loaded.

- [ ] **Step 4: Widen the audit predicate**

`app/controllers/concerns/admin_audit.rb`, `acting_as_operator?`. Keep the NAMING comment sub-project A added and change the test:

```ruby
  def acting_as_operator?(game)
    logged_in? && current_user.may_operate_commercial? && game.author_id != current_user.id
  end
```

Without this, an operator's acts on gated games they did not author go unrecorded — which is precisely the population the role exists to create.

- [ ] **Step 5: Run the specs**

Run: `bundle exec rspec spec/requests/operator_authority_spec.rb spec/requests/admin_audit_spec.rb spec/requests/admin_console_spec.rb spec/models/user`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Give the operator role its authority

The clause sub-project A specified and deferred, now that
Game#pass_required? exists to scope it. Game-conditional, not a bare
widening: ensure_author also gates levels, hints, questions and
entries, so the unscoped form would let an operator reach an ordinary
player's public game through its levels controller.

acting_as_operator? widens to may_operate_commercial?, without which an
operator's acts on games they did not author go unrecorded.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Final Verification

Run by the controller, not by a task subagent.

- [ ] **Full RSpec suite** — `bundle exec rspec`. Expected: 0 failures. **Measure the total; do not quote one from `CLAUDE.md`**, which has been stale five times. The pre-branch baseline on `feature/operator-role` was 2022 examples, 0 failures, 6 pending.

- [ ] **The inherited Cucumber contract** — this is the gate that proves the race path was not bent to fit the commercial one:

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: **228 scenarios (226 passed, 2 undefined) / 2325 steps**, unchanged. This plan edits no `.feature` file, so the counts cannot move; what matters is that they still pass.

- [ ] **Whole Cucumber suite** — `bundle exec cucumber`. Expected: 238 scenarios / 2386 steps, 0 failures.

- [ ] **Autoloading** — `bin/rails zeitwerk:check`. Expected: "All is good!"

- [ ] **Production boot** — the environment neither suite evaluates:

```bash
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u \
SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com \
DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'
```

- [ ] **No `.feature` file touched** — `git diff feature/operator-role --stat -- 'features/**/*.feature'` must be empty.

- [ ] **No `is_draft` survives** — `grep -rn "is_draft" app/ config/ lib/ db/schema.rb` must be empty (matches in `db/migrate/` and `spec/` are expected; see Task 2, Step 5).

- [ ] **Locale completeness** — for each of the ~16 keys this plan adds, confirm it exists in all seven files. `spec/i18n_spec.rb` only proves `ru`↔`en`, so check the other five by hand:

```bash
for k in no_access_pass issued_notice revoked_notice not_found cannot_revoke_started; do
  echo "== $k"; grep -L "$k" config/locales/{ru,en,uk,ka,tr,be,pl}.yml
done
```

Any file printed is missing that key.
