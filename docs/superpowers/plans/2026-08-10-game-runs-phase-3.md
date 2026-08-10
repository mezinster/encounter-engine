# Game Runs, Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin open a second run on a finished game, let teams register for it normally, and keep every earlier run's standings readable.

**Architecture:** `Game#open_run!` becomes the single writer that creates a run, called from one new admin action. `GameEntry` becomes run-scoped — including its unique index, which currently bars every returning team. The results page takes an optional `?run=<ordinal>` and grows a switcher that renders nothing when a game has one run.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec, sqlite in dev/test, PostgreSQL in production. Migrations run under `bin/docker-entrypoint`'s `db:prepare` before puma starts.

**Spec:** `docs/superpowers/specs/2026-08-10-game-runs-phase-3-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix every command with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any file under `features/`.** This plan touches none.
- **Cucumber must stay at exactly 232 scenarios (230 passed, 2 undefined) / 2342 steps** after every task. This is the first phase users can see, so it is the first where a frozen scenario could legitimately notice something — if one breaks, the design is wrong, not the scenario.
- **A single-run game must render byte-identically to today.** The run switcher emits nothing at all when `game.runs.size == 1`.
- **Every new user-facing string needs a key in all seven locale files** (`ru,en,uk,ka,tr,be,pl`). `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity. Turkish never lets a case suffix land on an interpolated value.
- **New audit actions need a label** under `admin.audit.index.action.*` in all seven files. The audit view falls back to the raw identifier, so a forgotten label fails nowhere — assert the identifier is **absent** from the log.
- **`GameRun`'s new validations are `on: :create` only.** `Game` has `autosave: true` on `:runs`, and `finish_game!` saves a game whose `starts_at` is long past; an unconditional validation would raise on exactly those games. See Task 1.
- **Do not scope logs, the live channel or the author's passings list.** They stay on the current run (spec §9).
- **Hash-rocket style** (`:key => value`), comments in English, user-facing strings in Russian.
- Run `bin/rails db:test:prepare` after the migration task. Commit after every task.

---

### Task 1: `GameRun` validates itself, and `Game#open_run!` creates one

**Files:**
- Modify: `app/models/game_run.rb`
- Modify: `app/models/game.rb` (add `open_run!` next to `transfer_authorship_to!`)
- Test: `spec/models/game/open_run_spec.rb` (create)

**Interfaces:**
- Produces: `Game#open_run!(attrs)` → the new `GameRun` (ordinal = current max + 1). Raises nothing; the caller does the refusing. `GameRun` validates `starts_at`, `registration_deadline` and `max_team_number` **on create only**. Tasks 3 consumes `open_run!`.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game/open_run_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The single writer that creates a run, mirroring transfer_authorship_to!.
# See docs/superpowers/specs/2026-08-10-game-runs-phase-3-design.md.
RSpec.describe Game, "#open_run!" do
  let(:game) { create_game }

  def valid_attrs(overrides = {})
    { :starts_at => 2.years.from_now,
      :registration_deadline => 23.months.from_now,
      :max_team_number => 10 }.merge(overrides)
  end

  it "creates the next ordinal" do
    run = game.open_run!(valid_attrs)

    expect(run.ordinal).to eq(2)
    expect(game.runs.reload.map(&:ordinal)).to eq([ 1, 2 ])
  end

  it "makes the new run the current one" do
    run = game.open_run!(valid_attrs)

    expect(game.reload.current_run).to eq(run)
  end

  it "carries the schedule it was given" do
    run = game.open_run!(valid_attrs(:max_team_number => 42))

    expect(run.max_team_number).to eq(42)
  end

  # Capacity is per run from phase 1, so a new run starts empty however full
  # the previous one was.
  it "starts with an empty team counter" do
    game.current_run.update_column(:requested_teams_number, 7)

    expect(game.open_run!(valid_attrs).requested_teams_number).to eq(0)
  end

  it "leaves the previous run untouched" do
    first = game.current_run
    before = first.attributes

    game.open_run!(valid_attrs)

    expect(first.reload.attributes).to eq(before)
  end

  describe "validation, on create only" do
    it "refuses a start time in the past" do
      run = game.runs.build(valid_attrs(:starts_at => 1.hour.ago).merge(:ordinal => 2))

      expect(run).not_to be_valid
      expect(run.errors[:starts_at]).not_to be_empty
    end

    it "refuses a registration deadline after the start" do
      run = game.runs.build(valid_attrs(:registration_deadline => 3.years.from_now).merge(:ordinal => 2))

      expect(run).not_to be_valid
      expect(run.errors[:registration_deadline]).not_to be_empty
    end

    it "refuses a missing team cap" do
      run = game.runs.build(valid_attrs(:max_team_number => nil).merge(:ordinal => 2))

      expect(run).not_to be_valid
      expect(run.errors[:max_team_number]).not_to be_empty
    end

    # THE trap. Game has autosave: true on :runs, and finish_game! saves a game
    # whose starts_at is long past. An unconditional validation here would
    # raise on exactly the games that method exists for -- which is why phase 1
    # (D4) left these on Game in the first place.
    it "does not re-validate an existing run when its game is saved" do
      running = create_game(:is_draft => false)
      set_game_schedule!(running, :starts_at => 1.hour.ago)

      expect { running.finish_game! }.not_to raise_error
      expect(running.reload).to be_author_finished
    end

    it "does not block an ordinary save of a game whose run is long past" do
      running = create_game(:is_draft => false)
      set_game_schedule!(running, :starts_at => 1.hour.ago, :author_finished_at => Time.now)

      expect { running.reload.save! }.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/open_run_spec.rb
```

Expected: FAIL with `NoMethodError: undefined method 'open_run!'`, and the validation examples fail because `GameRun` validates nothing yet.

- [ ] **Step 3: Add the validations to `GameRun`**

In `app/models/game_run.rb`, after the existing `validates :ordinal` block:

```ruby
  # on: :create, and this is not a style preference. Game declares
  # `has_many :runs, autosave: true`, so every `game.save` re-validates its
  # runs -- and finish_game! saves a game whose starts_at is long past. An
  # unconditional check here would raise on exactly the games that method
  # exists for.
  #
  # Phase 1 (D4) left these on Game for the same reason and recorded that a run
  # first becomes creatable without a game form in front of it in phase 3. It
  # is only the CREATE of a new run that needs checking; an existing run's
  # schedule ages past naturally and must stay saveable.
  validates :max_team_number, presence: true,
                              numericality: { greater_than: 0, less_than: 10000 },
                              on: :create
  validate :starts_in_the_future, on: :create
  validate :deadline_is_before_start, on: :create

  private

  def starts_in_the_future
    return if starts_at.nil? || starts_at > Time.now

    errors.add(:starts_at, I18n.t("activerecord.errors.models.game.attributes.starts_at.in_the_past"))
  end

  def deadline_is_before_start
    return if registration_deadline.nil? || starts_at.nil?
    return if registration_deadline <= starts_at

    errors.add(:registration_deadline,
               I18n.t("activerecord.errors.models.game.attributes.registration_deadline.after_game_start"))
  end
```

The messages are looked up from **`game`'s** existing keys rather than new `game_run` ones: the sentences are identical, they are already translated in all seven locales, and duplicating them would give two strings to keep in step. No locale file changes in this task.

- [ ] **Step 4: Add `Game#open_run!`**

In `app/models/game.rb`, immediately after `transfer_authorship_to!`:

```ruby
  # The single writer that creates a run, mirroring transfer_authorship_to!
  # above. Nothing else builds one except Game#current_run's autobuild, which
  # only ever produces the first.
  #
  # Deliberately does no refusing: whether this game is ALLOWED a new run --
  # its current one finished, at least one level -- is the caller's question,
  # and Admin::GamesController#open_run answers it before anything changes, the
  # shape every administrative action in this codebase uses.
  def open_run!(attrs)
    runs.create!(attrs.merge(:ordinal => runs.reload.maximum(:ordinal).to_i + 1))
  end
```

- [ ] **Step 5: Run the spec, then the full suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/open_run_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file PASSes 10 examples; RSpec 0 failures; Cucumber **232 / 2342**.

If anything else in the suite fails here, it is almost certainly a game whose save now re-validates a past-dated run — meaning an `on: :create` was missed.

- [ ] **Step 6: Commit**

```bash
git add app/models/game_run.rb app/models/game.rb spec/models/game/open_run_spec.rb
git commit -m "Let a game open another run

open_run! is the single writer that creates one, mirroring
transfer_authorship_to!, and deliberately does no refusing -- whether a
game may have another run is the caller's question.

GameRun validates its schedule on: :create only. Game declares
has_many :runs, autosave: true, so an unconditional validation would
re-check an existing run on every game.save -- and finish_game! saves a
game whose starts_at is long past, which is exactly why phase 1 left
these on Game."
```

---

### Task 2: Entries become run-scoped, and the index stops barring returning teams

The blocker from spec §2.1. `UNIQUE (team_id, game_id) WHERE status IN ('new','accepted')` means every team that played run 1 is permanently barred from applying to any later run.

**Files:**
- Create: `db/migrate/20260810180000_move_game_entries_unique_index_to_run.rb`
- Modify: `app/models/game_entry.rb`
- Modify: `app/controllers/game_passings_controller.rb` (`may_start_passing?`)
- Modify: `app/controllers/game_entries_controller.rb:22`
- Modify: `app/controllers/games_controller.rb:51-52`
- Modify: `app/controllers/dashboard_controller.rb:12`
- Modify: `app/views/dashboard/_coming_games.html.erb:13`, `app/views/shared/_countdown.html.erb:46`, `app/views/shared/_current_games.html.erb:16`
- Test: `spec/requests/run_scoped_entries_spec.rb` (create)
- Modify: `db/schema.rb` (regenerated)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `GameEntry.of(team, run)` — **signature change**, takes a run. `GameEntry.of_run(run)` scope. Entries are created with `game_run_id`. Task 3 relies on a new run having no entries.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/run_scoped_entries_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Admission belongs to a run. Every example builds a second run, because with
# one run a run-scoped entry query returns exactly what the game-scoped one
# returned and would pass either way.
describe "entries scoped to a run", type: :request do
  let(:author)  { create_user }
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }
  let(:game) do
    g = create_game(:author => author, :is_draft => false, :max_team_number => 10)
    create_level(:game => g)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def second_run(g)
    g.open_run!(:starts_at => 2.years.from_now,
                :registration_deadline => 23.months.from_now,
                :max_team_number => 10)
    g.reload
  end

  # THE blocker. Run 1's entries stay "accepted" for ever, and the old unique
  # index was on (team_id, game_id) for live statuses -- so this application
  # was refused by the database with an opaque uniqueness error.
  it "lets a team accepted in run 1 apply to run 2" do
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => team, :status => "accepted")
    second_run(game)
    captain.reload
    sign_in(captain)

    expect {
      post new_game_entry_path(:game_id => game.id, :team_id => team.id)
    }.to change { GameEntry.where(:game_run_id => game.current_run.id).count }.by(1)
  end

  it "does not let a team play run 2 on its run 1 acceptance alone" do
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => team, :status => "accepted")
    second_run(game)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    captain.reload
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
  end

  it "lets it play run 2 once it is accepted there" do
    second_run(game)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => team, :status => "accepted")
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    captain.reload
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
  end

  it "counts a new run's capacity from zero" do
    game.current_run.update_column(:requested_teams_number, 9)
    run_two = second_run(game).current_run

    expect(run_two.requested_teams_number).to eq(0)
  end

  # The author's pending list belongs to the run being registered for.
  it "shows the author only the current run's pending entries" do
    old_team = create_team(:captain => create_user)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => old_team, :status => "new")
    second_run(game)
    new_team = create_team(:captain => create_user)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => new_team, :status => "new")
    sign_in(author)

    get game_path(game)

    expect(response.body).to include(new_team.name)
    expect(response.body).not_to include(old_team.name)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/run_scoped_entries_spec.rb
```

Expected: FAIL. The first example fails with `ActiveRecord::RecordNotUnique` — the index refusing the returning team, which is the blocker this task removes.

- [ ] **Step 3: Write the index migration**

Create `db/migrate/20260810180000_move_game_entries_unique_index_to_run.rb`:

```ruby
# The live-entry uniqueness moves from the GAME to the RUN.
#
# db/migrate/20260808070000 added UNIQUE (team_id, game_id) WHERE status IN
# ('new','accepted') to stop a double-clicked "apply" creating two
# simultaneously live entries. Run 1's entries stay "accepted" for ever, so
# once a game can have a second run that index permanently bars every team
# that played run 1 from applying to any later one -- enforced by the
# database, with an opaque uniqueness error and nothing a captain could act
# on.
#
# The invariant it protects is unchanged; only its scope moves.
class MoveGameEntriesUniqueIndexToRun < ActiveRecord::Migration[8.0]
  LIVE_STATUSES = %w[new accepted].freeze
  OLD_INDEX = "index_game_entries_on_team_id_and_game_id_live".freeze
  NEW_INDEX = "index_game_entries_on_team_id_and_game_run_id_live".freeze

  def up
    # Check before adding, and say rather than raise. Migrations run under
    # bin/docker-entrypoint's db:prepare BEFORE puma starts, so an index that
    # raises on unexpected data takes the whole app down mid-deploy,
    # recoverable only by someone shelling in. Production had 4 entries when
    # this was written; the guard is for restored or future data.
    duplicates = GameEntry.where(:status => LIVE_STATUSES)
                          .where.not(:game_run_id => nil)
                          .group(:team_id, :game_run_id)
                          .having("COUNT(*) > 1")
                          .count

    if duplicates.any?
      say "SKIPPED: #{duplicates.size} (team_id, game_run_id) pair(s) have more than one " \
          "live-status game_entries row -- new index NOT added and the old one LEFT IN " \
          "PLACE. Resolve the duplicates and re-run. Pairs: #{duplicates.keys.inspect}"
      return
    end

    add_index :game_entries, [ :team_id, :game_run_id ],
              unique: true,
              where: "status IN ('new', 'accepted')",
              name: NEW_INDEX

    # Only once the replacement is in place: dropping first would leave a
    # window with no protection at all if the add then failed.
    remove_index :game_entries, name: OLD_INDEX, if_exists: true
    say "moved live-entry uniqueness from (team_id, game_id) to (team_id, game_run_id)"
  end

  def down
    add_index :game_entries, [ :team_id, :game_id ],
              unique: true,
              where: "status IN ('new', 'accepted')",
              name: OLD_INDEX
    remove_index :game_entries, name: NEW_INDEX, if_exists: true
  end
end
```

- [ ] **Step 4: Make `GameEntry` run-scoped**

In `app/models/game_entry.rb`, add the scope and change `self.of`:

```ruby
  scope :of_run, ->(run) { where(:game_run_id => run.id) }
```

```ruby
  # Takes a RUN, not a game: admission belongs to one running of it, and in
  # phase 3 a team may hold an entry in several runs of the same game.
  #
  # The accepted-first preference below is unchanged and still load-bearing --
  # see the comment above about a rejected earlier entry shadowing a later
  # accepted one.
  def self.of(team, run)
    scope = of_team(team).of_run(run)
    scope.with_status("accepted").first || scope.first
  end
```

- [ ] **Step 5: Move the seven call sites**

`app/controllers/game_passings_controller.rb#may_start_passing?`:

```ruby
    GameEntry.of(@team, @game.current_run)&.status == "accepted"
```

`app/controllers/game_entries_controller.rb:21-25` — note this deliberately does **not** use `.of`; its comment explains that an existing rejected row must still block a fresh apply, so the accepted-first bias is wrong here. Keep that, scoped to the run:

```ruby
  def new
    if @game.can_request? && !GameEntry.of_team(@team).of_run(@game.current_run).exists?
      @game_entry = GameEntry.create!(status: "new", game: @game,
                                      game_run: @game.current_run, team: @team)
      @game.reserve_place_for_team!
    end
    redirect_to dashboard_path
  end
```

`app/controllers/games_controller.rb:51-52`:

```ruby
    @game_entries = GameEntry.of_run(@game.current_run).with_status("new")
    @teams = GameEntry.of_run(@game.current_run).with_status("accepted").map(&:team)
```

`app/controllers/dashboard_controller.rb:12`:

```ruby
      @game_entries.concat(GameEntry.of_run(game.current_run).with_status("new").to_a)
```

`app/views/dashboard/_coming_games.html.erb:13`:

```erb
          <% @game_entry = GameEntry.of(@team, game.current_run) %>
```

`app/views/shared/_countdown.html.erb:46`:

```erb
          @game_entry = GameEntry.of(@team, @game.current_run)
```

`app/views/shared/_current_games.html.erb:16`:

```erb
                  <%  @game_entry = GameEntry.of(@team, game.current_run) %>
```

- [ ] **Step 6: Migrate and run the new spec**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
bundle exec rspec spec/requests/run_scoped_entries_spec.rb
```

Expected: PASS, 5 examples, 0 failures.

- [ ] **Step 7: Confirm nothing still asks the game for an entry**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "GameEntry.of_game\|GameEntry.of(" app/
```

Expected: only `GameEntry.of(..., ...current_run)` forms. **No `GameEntry.of_game` call should remain** — the scope itself may stay defined.

- [ ] **Step 8: Run both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec 0 failures. Cucumber **232 / 2342**. Registration and the dashboard entry lists are frozen-scenario territory, so Cucumber matters here.

- [ ] **Step 9: Commit**

```bash
git add db/migrate app/ spec/ db/schema.rb
git commit -m "Scope admission to the run

The live-entry unique index moves from (team_id, game_id) to
(team_id, game_run_id). Run 1's entries stay accepted for ever, so on a
game with a second run the old index permanently barred every returning
team -- from the database, with an opaque error. The new index is added
before the old one is dropped, so there is never a window with no
protection.

GameEntry.of now takes a run. GameEntriesController#new keeps NOT using
it: an existing rejected row must still block a fresh apply, which the
accepted-first bias would hide."
```

---

### Task 3: The superadmin opens a run

**Files:**
- Modify: `config/routes.rb` (admin games member route)
- Modify: `app/controllers/admin/games_controller.rb`
- Modify: `app/views/admin/games/index.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Modify: `spec/requests/admin_audit_spec.rb`
- Test: `spec/requests/admin_open_run_spec.rb` (create)

**Interfaces:**
- Consumes: `Game#open_run!(attrs)` from Task 1.
- Produces: route helper `open_run_admin_game_path(game)` → `POST /admin/games/:id/open_run`, params `:starts_at`, `:registration_deadline`, `:max_team_number`.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/admin_open_run_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Opening a run is the console's second non-index action, alongside set_author.
describe "opening a run as an operator", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def valid_params
    { :starts_at => 2.years.from_now.strftime("%Y-%m-%d %H:%M"),
      :registration_deadline => 23.months.from_now.strftime("%Y-%m-%d %H:%M"),
      :max_team_number => "10" }
  end

  it "opens the next run and says so" do
    sign_in(operator)

    expect {
      post open_run_admin_game_path(game), :params => valid_params
    }.to change { game.runs.reload.count }.by(1)

    expect(game.reload.current_run.ordinal).to eq(2)
    expect(response).to redirect_to(admin_games_path)
    expect(flash[:notice]).to eq(I18n.t("admin.games.run_opened", :ordinal => 2))
  end

  it "refuses while the current run is unfinished" do
    unfinished = create_game(:author => author, :is_draft => false)
    create_level(:game => unfinished)
    sign_in(operator)

    expect {
      post open_run_admin_game_path(unfinished), :params => valid_params
    }.not_to change { unfinished.runs.reload.count }

    expect(flash[:alert]).to eq(I18n.t("admin.games.cannot_open_unfinished"))
  end

  it "refuses a game with no levels" do
    empty = create_game(:author => author, :is_draft => false)
    set_game_schedule!(empty, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    sign_in(operator)

    expect {
      post open_run_admin_game_path(empty), :params => valid_params
    }.not_to change { empty.runs.reload.count }

    expect(flash[:alert]).to eq(I18n.t("admin.games.cannot_open_without_levels"))
  end

  it "refuses an invalid schedule, reporting why" do
    sign_in(operator)

    expect {
      post open_run_admin_game_path(game),
           :params => valid_params.merge(:starts_at => 1.hour.ago.strftime("%Y-%m-%d %H:%M"))
    }.not_to change { game.runs.reload.count }

    expect(flash[:alert]).to be_present
  end

  it "refuses a player who is not a superadmin" do
    sign_in(author)

    expect {
      post open_run_admin_game_path(game), :params => valid_params
    }.not_to change { game.runs.reload.count }

    expect(response).to have_http_status(:unauthorized)
  end

  # Game#status reads the current run, so opening one takes a finished game
  # back to :scheduled -- it reappears in the public list and leaves
  # «Завершённые игры». That is correct (it is open for registration again),
  # and it is asserted rather than assumed because several listings key off it.
  it "puts the game back on the schedule" do
    expect(game.status).to eq(:finished)
    sign_in(operator)

    post open_run_admin_game_path(game), :params => valid_params

    expect(game.reload.status).to eq(:scheduled)
  end

  # The other half of the same fact: opening a run makes started? false, which
  # re-opens content editing. Recorded in spec §6 as a deliberate consequence
  # rather than a bug, and pinned here so a later change cannot quietly
  # reverse it without someone noticing.
  it "re-opens content editing for the author" do
    sign_in(operator)
    post open_run_admin_game_path(game), :params => valid_params

    sign_in(author)
    get edit_game_path(game)

    expect(response).to have_http_status(:ok)
  end

  describe "auditing" do
    it "records the ordinal it opened" do
      sign_in(operator)

      expect {
        post open_run_admin_game_path(game), :params => valid_params
      }.to change(AdminAction, :count).by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("open_run")
      expect(entry.target_type).to eq("Game")
      expect(entry.details).to eq("2")
    end

    it "writes nothing for a refused open" do
      unfinished = create_game(:author => author, :is_draft => false)
      create_level(:game => unfinished)
      sign_in(operator)

      expect {
        post open_run_admin_game_path(unfinished), :params => valid_params
      }.not_to change(AdminAction, :count)
    end

    # The audit view falls back to the raw action name on a missing key, so
    # only asserting the identifier is ABSENT catches a forgotten label.
    it "renders a sentence in the log, not the raw action name" do
      sign_in(operator)
      post open_run_admin_game_path(game), :params => valid_params

      get admin_audit_index_path

      expect(response.body).to include(I18n.t("admin.audit.index.action.open_run"))
      expect(response.body).not_to include("open_run")
    end
  end

  it "offers the form on the console" do
    listed = game
    sign_in(operator)

    get admin_games_path

    expect(response.body).to include(open_run_admin_game_path(listed))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_open_run_spec.rb
```

Expected: FAIL with `NameError: undefined local variable or method 'open_run_admin_game_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the admin `resources :games` block:

```ruby
    resources :games, only: [ :index ] do
      post "set_author", on: :member
      post "open_run",   on: :member
    end
```

- [ ] **Step 4: Add the locale keys**

Add to `admin: → games:` (siblings of `index:`) and inside `admin: → games: → index:`, in all seven files. Also the audit label under `admin: → audit: → index: → action:`.

`config/locales/ru.yml`:
```yaml
      run_opened: "Открыт забег №%{ordinal}"
      cannot_open_unfinished: "Нельзя открыть новый забег: текущий ещё не завершён"
      cannot_open_without_levels: "Нельзя открыть забег в игре без заданий"
```
```yaml
        open_run: "Открыть новый забег"
        run_starts_at: "Начало забега"
        run_deadline: "Регистрация до"
        run_max_teams: "Команд"
```
```yaml
          open_run: "Открыл новый забег"
```

`config/locales/en.yml`:
```yaml
      run_opened: "Run №%{ordinal} opened"
      cannot_open_unfinished: "Cannot open a new run: the current one has not finished"
      cannot_open_without_levels: "Cannot open a run in a game with no levels"
```
```yaml
        open_run: "Open a new run"
        run_starts_at: "Run starts at"
        run_deadline: "Registration until"
        run_max_teams: "Teams"
```
```yaml
          open_run: "Opened a new run"
```

`config/locales/uk.yml`:
```yaml
      run_opened: "Відкрито забіг №%{ordinal}"
      cannot_open_unfinished: "Не можна відкрити новий забіг: поточний ще не завершено"
      cannot_open_without_levels: "Не можна відкрити забіг у грі без завдань"
```
```yaml
        open_run: "Відкрити новий забіг"
        run_starts_at: "Початок забігу"
        run_deadline: "Реєстрація до"
        run_max_teams: "Команд"
```
```yaml
          open_run: "Відкрив новий забіг"
```

`config/locales/be.yml`:
```yaml
      run_opened: "Адкрыты забег №%{ordinal}"
      cannot_open_unfinished: "Нельга адкрыць новы забег: бягучы яшчэ не завершаны"
      cannot_open_without_levels: "Нельга адкрыць забег у гульні без заданняў"
```
```yaml
        open_run: "Адкрыць новы забег"
        run_starts_at: "Пачатак забегу"
        run_deadline: "Рэгістрацыя да"
        run_max_teams: "Каманд"
```
```yaml
          open_run: "Адкрыў новы забег"
```

`config/locales/pl.yml`:
```yaml
      run_opened: "Otwarto bieg nr %{ordinal}"
      cannot_open_unfinished: "Nie można otworzyć nowego biegu: bieżący nie został zakończony"
      cannot_open_without_levels: "Nie można otworzyć biegu w grze bez zadań"
```
```yaml
        open_run: "Otwórz nowy bieg"
        run_starts_at: "Początek biegu"
        run_deadline: "Rejestracja do"
        run_max_teams: "Drużyn"
```
```yaml
          open_run: "Otworzył nowy bieg"
```

`config/locales/tr.yml`:
```yaml
      run_opened: "%{ordinal}. koşu açıldı"
      cannot_open_unfinished: "Yeni koşu açılamaz: mevcut koşu henüz bitmedi"
      cannot_open_without_levels: "Görevi olmayan bir oyunda koşu açılamaz"
```
```yaml
        open_run: "Yeni koşu aç"
        run_starts_at: "Koşunun başlangıcı"
        run_deadline: "Kayıt bitişi"
        run_max_teams: "Takım"
```
```yaml
          open_run: "Yeni bir koşu açtı"
```

`config/locales/ka.yml`:
```yaml
      run_opened: "გაიხსნა გარბენი №%{ordinal}"
      cannot_open_unfinished: "ახალი გარბენის გახსნა შეუძლებელია: მიმდინარე ჯერ არ დასრულებულა"
      cannot_open_without_levels: "გარბენის გახსნა შეუძლებელია თამაშში დავალებების გარეშე"
```
```yaml
        open_run: "ახალი გარბენის გახსნა"
        run_starts_at: "გარბენის დაწყება"
        run_deadline: "რეგისტრაცია მდე"
        run_max_teams: "გუნდი"
```
```yaml
          open_run: "გახსნა ახალი გარბენი"
```

- [ ] **Step 5: Add the action**

In `app/controllers/admin/games_controller.rb`, after `set_author`:

```ruby
  # Opening another run of a finished game -- the console's second non-index
  # action. Every refusal returns BEFORE anything changes, matching set_author
  # and Admin::UsersController#revoke, so the log never holds an entry for a
  # change that did not happen.
  def open_run
    game = Game.find(params[:id])

    unless game.author_finished?
      redirect_to admin_games_path,
                  :alert => t("admin.games.cannot_open_unfinished") and return
    end

    if game.levels.empty?
      redirect_to admin_games_path,
                  :alert => t("admin.games.cannot_open_without_levels") and return
    end

    run = game.open_run!(:starts_at => params[:starts_at],
                         :registration_deadline => params[:registration_deadline],
                         :max_team_number => params[:max_team_number])

    record_admin_action("open_run", game, run.ordinal.to_s)
    redirect_to admin_games_path,
                :notice => t("admin.games.run_opened", :ordinal => run.ordinal)
  rescue ActiveRecord::RecordInvalid => e
    # The schedule is validated on the run (Task 1). Reporting its own message
    # rather than a generic one is what tells an operator WHICH field is wrong.
    redirect_to admin_games_path, :alert => e.record.errors.full_messages.to_sentence
  end
```

- [ ] **Step 6: Add the form to the console**

In `app/views/admin/games/index.html.erb`, inside the last `<td>`, after the `set_author` control block:

```erb
        <%# Only for a finished game: opening a run while the current one is
            still being played is refused by the action, and offering a control
            the action refuses is a promise the page cannot keep. %>
        <% if game.author_finished? && game.levels.any? %>
          <div class="game-control">
            <%= form_with url: open_run_admin_game_path(game), method: :post do %>
              <%= label_tag "run_starts_at_#{game.id}", t("admin.games.index.run_starts_at") %>
              <%= text_field_tag :starts_at, nil, :id => "run_starts_at_#{game.id}", :autocomplete => "off" %>
              <%= label_tag "run_deadline_#{game.id}", t("admin.games.index.run_deadline") %>
              <%= text_field_tag :registration_deadline, nil, :id => "run_deadline_#{game.id}", :autocomplete => "off" %>
              <%= label_tag "run_max_teams_#{game.id}", t("admin.games.index.run_max_teams") %>
              <%= text_field_tag :max_team_number, game.max_team_number, :id => "run_max_teams_#{game.id}", :autocomplete => "off" %>
              <%= submit_tag t("admin.games.index.open_run"), :class => "btn" %>
            <% end %>
          </div>
        <% end %>
```

- [ ] **Step 7: Add the audit action to the enumerated list**

In `spec/requests/admin_audit_spec.rb`, inside `describe "the explicitly superadmin actions"`:

```ruby
    it "records opening a run" do
      finished = create_game(:author => author, :is_draft => false)
      create_level(:game => finished)
      set_game_schedule!(finished, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)

      expect do
        post open_run_admin_game_path(finished),
             :params => { :starts_at => 2.years.from_now.strftime("%Y-%m-%d %H:%M"),
                          :registration_deadline => 23.months.from_now.strftime("%Y-%m-%d %H:%M"),
                          :max_team_number => "10" }
      end.to change { AdminAction.count }.by(1)

      expect(AdminAction.newest_first.first.action).to eq("open_run")
    end
```

- [ ] **Step 8: Run the specs, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_open_run_spec.rb spec/requests/admin_audit_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: PASS throughout; Cucumber **232 / 2342**.

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/controllers/admin/games_controller.rb app/views/admin/games/index.html.erb config/locales spec/
git commit -m "Let a superadmin open another run

The console's second non-index action. Every refusal returns before
anything changes, so the audit log never holds an entry for an open
that did not happen, and the form is offered only on a finished game
with levels -- offering a control the action refuses is a promise the
page cannot keep.

An invalid schedule reports the run's own validation message rather
than a generic one, which is what tells an operator which field is
wrong."
```

---

### Task 4: The results run switcher

**Files:**
- Modify: `app/controllers/game_passings_controller.rb` (`show_results`)
- Modify: `app/views/game_passings/show_results.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/results_run_switcher_spec.rb` (create)

**Interfaces:**
- Consumes: `Game#open_run!` from Task 1, `GameRun#place_of` from phase 2.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/results_run_switcher_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Opening a run must not make the previous run's standings unreachable -- that
# is the history this whole programme exists to preserve.
describe "the results page across runs", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end
  let(:level) { game.levels.first }

  def finished_team(run, finished_at)
    team = create_team(:captain => create_user)
    passing = create_game_passing(:level => level, :team => team, :game_run => run)
    passing.update_column(:finished_at, finished_at)
    team
  end

  def open_second_run
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
  end

  it "shows the current run by default" do
    old_team = finished_team(game.current_run, 2.days.ago)
    open_second_run
    new_team = finished_team(game.current_run, 1.hour.ago)

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).to include(new_team.name)
    expect(response.body).not_to include(old_team.name)
  end

  # THE point of the phase: run 1's frozen table stays readable.
  it "shows an earlier run when asked for it by ordinal" do
    old_team = finished_team(game.current_run, 2.days.ago)
    open_second_run
    new_team = finished_team(game.current_run, 1.hour.ago)

    get game_passings_show_results_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(old_team.name)
    expect(response.body).not_to include(new_team.name)
  end

  it "falls back to the current run for an unknown ordinal" do
    finished_team(game.current_run, 2.days.ago)
    open_second_run
    new_team = finished_team(game.current_run, 1.hour.ago)

    get game_passings_show_results_path(:game_id => game.id, :run => 99)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(new_team.name)
  end

  it "falls back to the current run for a malformed ordinal" do
    finished_team(game.current_run, 2.days.ago)
    open_second_run
    new_team = finished_team(game.current_run, 1.hour.ago)

    get game_passings_show_results_path(:game_id => game.id, :run => "не-число")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(new_team.name)
  end

  it "ranks within the run being shown" do
    first  = finished_team(game.current_run, 3.days.ago)
    second = finished_team(game.current_run, 2.days.ago)
    open_second_run

    get game_passings_show_results_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(first.name)
    expect(response.body).to include(second.name)
  end

  it "offers a switcher once a second run exists" do
    open_second_run

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).to include(game_passings_show_results_path(:game_id => game.id, :run => 1))
  end

  # THE frozen-scenario guard. Today's page must be byte-identical for the only
  # shape production has: one run.
  it "renders no switcher at all for a game with one run" do
    finished_team(game.current_run, 2.days.ago)

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).not_to include(I18n.t("game_passings.show_results.runs_heading"))
    expect(response.body).not_to include(game_passings_show_results_path(:game_id => game.id, :run => 1))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/results_run_switcher_spec.rb
```

Expected: FAIL — `?run=1` shows the current run, and `game_passings.show_results.runs_heading` raises `I18n::MissingTranslationData`.

- [ ] **Step 3: Add the locale keys**

Inside `game_passings: → show_results:` in all seven files:

```yaml
# ru.yml
      runs_heading: "Забеги:"
      run_label: "Забег №%{ordinal} — %{date}"
# en.yml
      runs_heading: "Runs:"
      run_label: "Run №%{ordinal} — %{date}"
# uk.yml
      runs_heading: "Забіги:"
      run_label: "Забіг №%{ordinal} — %{date}"
# be.yml
      runs_heading: "Забегі:"
      run_label: "Забег №%{ordinal} — %{date}"
# pl.yml
      runs_heading: "Biegi:"
      run_label: "Bieg nr %{ordinal} — %{date}"
# tr.yml
      runs_heading: "Koşular:"
      run_label: "%{ordinal}. koşu — %{date}"
# ka.yml
      runs_heading: "გარბენები:"
      run_label: "გარბენი №%{ordinal} — %{date}"
```

- [ ] **Step 4: Resolve the run in the controller**

In `app/controllers/game_passings_controller.rb`, replace `show_results`:

```ruby
  # The ORDINAL, not the id: stable, human-readable, and meaningful in a URL a
  # player might share. Absent, unknown or malformed falls back to the current
  # run rather than 404ing -- a stale bookmark should show the current
  # standings, not an error.
  def show_results
    @run = @game.runs.find_by(:ordinal => params[:run].to_i) || @game.current_run
  end
```

- [ ] **Step 5: Render the chosen run and the switcher**

In `app/views/game_passings/show_results.html.erb`, change line 16 and the place column, and add the switcher above the table:

```erb
<% game_passings = @run.passings %>
```

```erb
        <td data-label="<%= t("game_passings.show_results.place") %>"><%= @run.place_of(game_passing.team) %></td>
```

And immediately before `<div class="table-wrap">`:

```erb
<%# Nothing at all for a game with one run: that is every game in production
    today, and several frozen scenarios assert on this page. %>
<% if @game.runs.size > 1 %>
  <p>
    <strong><%= t("game_passings.show_results.runs_heading") %></strong>
    <% @game.runs.each do |run| %>
      <% label = t("game_passings.show_results.run_label",
                   :ordinal => run.ordinal,
                   :date => run.starts_at ? l(run.starts_at.to_date, :format => :long) : "—") %>
      <% if run == @run %>
        <strong><%= label %></strong>
      <% else %>
        <%= link_to label, game_passings_show_results_path(:game_id => @game.id, :run => run.ordinal) %>
      <% end %>
    <% end %>
  </p>
<% end %>
```

The `zone_reference` line above it stays on `@game.starts_at`; it reports the display zone, which is the same for every run.

- [ ] **Step 6: Run the spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/results_run_switcher_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: the new file PASSes 7 examples; RSpec 0 failures; Cucumber **232 / 2342**; `All is good!`.

The single-run example and Cucumber are the same guarantee from two directions: today's results page is unchanged.

- [ ] **Step 7: Boot the production environment**

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
git add app/ config/locales spec/
git commit -m "Let the results page show an earlier run

Takes the ordinal, not the id: stable and meaningful in a URL a player
might share. Absent, unknown or malformed falls back to the current run
rather than 404ing, because a stale bookmark should show the current
standings.

The switcher renders nothing at all for a game with one run, which is
every game in production today and what keeps the frozen scenarios
green."
```

---

## Before deploying

**Rehearse the migration against a copy of production**, the same way phases 1 and 2 were:

```bash
ssh mezin 'RESTORE_POINT=latest KEEP_SCRATCH=yes bash -s' < ops/db-restore-scratch.sh
```

Then run the migration from the app image against the scratch container and check:

```sql
-- the new index exists and the old one is gone
SELECT indexname FROM pg_indexes WHERE tablename = 'game_entries';

-- no live entry lost its run
SELECT count(*) FROM game_entries
 WHERE status IN ('new','accepted') AND game_run_id IS NULL;         -- must be 0

-- the guard's own question: nothing would have made it skip
SELECT count(*) FROM (SELECT team_id, game_run_id FROM game_entries
                       WHERE status IN ('new','accepted') AND game_run_id IS NOT NULL
                       GROUP BY team_id, game_run_id HAVING count(*) > 1) d;  -- must be 0
```

If the third is non-zero the migration `say`s, **leaves the old index in place**, and completes — the app stays up and registration keeps working under the old rule, but returning teams are still barred until someone resolves the duplicates.

Destroy the scratch container and volume afterwards, and remove anything copied to the host.

**Rollback** is `kamal rollback`. The migration is index-only — no column is added or dropped, and no data moves — so the previous image works against the new schema with one exception: under the old code a team could hold live entries in two runs of one game, which the old index would have refused. That cannot arise until a second run exists, so rolling back before anyone opens one is completely safe.
