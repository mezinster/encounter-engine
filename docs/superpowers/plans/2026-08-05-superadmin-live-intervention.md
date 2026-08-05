# Superadmin Live-Game Intervention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an operator something between watching a running game and killing it — move a stuck team to a level, reinstate a team that quit by accident, reset a team's hint clock, and pause and resume the whole game with countdowns frozen.

**Architecture:** Every intervention is a named method on `GamePassing` or `Game` that leaves the record in a state ordinary gameplay could also have produced; no form writes a column directly. A new `InterventionsController` holds the five actions and renders nothing, redirecting back to the existing stats page, which grows the controls. Pausing works by freezing an *effective now* that hint arithmetic reads, so one concept covers the view, the JSON poller and the stats clock.

**Tech Stack:** Ruby 3.3.12, Rails 8.0.5.1, SQLite (dev/test), PostgreSQL (production), RSpec 3.13.

## Global Constraints

- Ruby is pinned to `3.3.12` and Rails to `8.0.5.1`. Do not change either.
- rbenv is not on PATH in non-login shells. Prefix every Ruby command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never create, edit or delete any file under `features/`.** Those `.feature` files are the contract the Merb→Rails port was validated against, whitespace included.
- Existing gates must stay green: `bundle exec rspec` is **583 examples, 0 failures, 6 pending**; `bundle exec cucumber` is **234 scenarios (2 pre-existing "undefined" placeholders), 2362 steps**. `bin/rails zeitwerk:check` must print `All is good!`.
- **No form or action writes a `GamePassing` or `Game` column directly.** Each intervention is a named model method. A generic state editor was considered and rejected: it lets an operator produce rows the model has no path to (`finished_at` set with `status` nil, a `current_level` from another game) that no test covers.
- **A moved or reinstated team must not be left in a contradictory state.** A team standing on a level is by definition not finished, so any action that puts a team back on a level clears `finished_at` and `status` in the same operation.
- **`Log` rows are never touched by any intervention.** History stays honest; the audit trail records who intervened.
- **Interventions are audited under sub-project B's rule:** recorded when a superadmin acts on someone else's game, silent when an author acts on their own, and only after the change lands.
- **Platform chrome goes through `t()`;** author-written content renders verbatim. New keys go in all four of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb` enforces `ru`↔`en` exact parity and `uk`/`ka` as a subset; `raise_on_missing_translations` is on in test. **On this branch `uk`/`ka` are stubs holding Russian text** — use the Russian value there and say so in your report.
- Factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb`. No FactoryBot. `create_user` takes **no arguments**. New specs use `expect`.
- Refusal assertions use the specific status (`have_http_status(:unauthorized)`, or `:found` plus `redirect_to(login_path)` for anonymous requests) — never `not_to have_http_status(:ok)`, which a 500 also satisfies.
- Hash rockets (`:key => value`) are the surrounding style in these models, controllers and views.
- **Out of scope:** editing or deleting `Log` rows; annotating results to mark assisted teams; a generic `GamePassing` editor; a free-text pause reason; automatic or scheduled pause; fixing the pre-existing bug where `exit!` sets `finished_at` so a quitting team appears in `finished_teams`.

### Facts verified against this app while writing this plan

Do not re-derive these; do check anything this plan does *not* state.

- **A running game fails its own validations.** `Game#game_starts_in_the_future` adds an error whenever `author_finished_at` is nil and `starts_at` is in the past — true of every game being played. Verified: a `Game` with `starts_at` an hour ago and no `author_finished_at` reports `["Starts at Вы выбрали дату из прошлого. Так нельзя :-)"]`. **Therefore every write to a live `Game` row must use `update_column`**; `update!` raises `RecordInvalid` and `update` fails silently. This is the same trap that makes `reserve_place_for_team!` stop enforcing `max_team_number` once a game starts.
- `SecurityFilters#ensure_author` already means "the author, **or any superadmin**" — it returns early for superadmins. `ensure_editing_not_locked` also exempts superadmins. Together they produce C's whole authorization rule with no new concept.
- `Hint#ready_to_show?(entered_at)` is `Time.now - entered_at >= self.delay`. `Hint#available_in(entered_at)` is `(entered_at - Time.now).to_i + self.delay`. Nothing stores elapsed countdown.
- `GamePassing#pass_level!` already clears answered questions and stamps `current_level_entered_at`; `exit!` sets `finished_at` **and** `status = "exited"` but leaves the entry clock untouched.
- `Level` uses `acts_as_list :scope => :game`; `Level#next` is `lower_item`; `scope :of_game`.
- The stats page route is `get "/stats/:action/:game_id", controller: "game_passings", as: :game_stats`. **`game_stats_path(:index, 7)` produces `/stats/index/7`** — verified.
- `AdminAudit#record_admin_action(action, target = nil)` writes `actor_id`, `action`, `target_type`, `target_id`, `target_label`. `GamesController` has a private `acting_as_operator?` taking no arguments and reading `@game`.
- `Admin::AuditController#index` loads `@entries` eagerly with `.to_a` and builds `@live_games`/`@live_users` id sets via a private `live_ids(klass, type)`.
- `create_game_passing(:level => lvl)` derives its game from the level and creates its own team. `create_level(:game => g)`, `create_hint(:level => l, :delay => seconds)`.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/<ts>_add_details_to_admin_actions.rb` | Audit detail column |
| `db/migrate/<ts>_add_paused_at_to_games.rb` | Pause state |
| `app/controllers/interventions_controller.rb` | The five actions |
| `app/views/game_passings/_intervention_controls.html.erb` | Per-team controls + pause banner |
| `spec/models/game_passing/interventions_spec.rb` | The three team-scoped methods |
| `spec/models/game/pausing_spec.rb` | Pause, resume, the shift arithmetic |
| `spec/requests/interventions_spec.rb` | Authorization matrix, audit, reachability |
| `spec/requests/paused_gameplay_spec.rb` | What a player can and cannot do while paused |

**Modified:**

| File | Change |
|---|---|
| `app/controllers/concerns/admin_audit.rb` | `details` argument; `acting_as_operator?(game)` moves here |
| `app/controllers/games_controller.rb` | Call sites pass `@game` to `acting_as_operator?` |
| `app/controllers/concerns/security_filters.rb` | `ensure_game_is_live` |
| `app/models/admin_action.rb` | (none — `details` is a plain column) |
| `app/models/game.rb` | `paused?`, `pause!`, `resume!` |
| `app/models/game_passing.rb` | `effective_now`, three intervention methods, frozen clock |
| `app/models/hint.rb` | `ready_to_show?`/`available_in` take an explicit `now` |
| `app/controllers/game_passings_controller.rb` | Frozen tip clock; refuse play while paused |
| `app/views/game_passings/index.html.erb` | Controls column, pause banner |
| `app/views/game_passings/show_current_level.html.erb` | Paused banner |
| `app/views/admin/audit/index.html.erb` | Render `details` when present |
| `config/routes.rb` | Five intervention routes |
| `config/locales/{ru,en,uk,ka}.yml` | New chrome keys |

---

### Task 1: The audit `details` column and a shared operator test

**Files:**
- Create: `db/migrate/<ts>_add_details_to_admin_actions.rb`
- Modify: `app/controllers/concerns/admin_audit.rb`, `app/controllers/games_controller.rb`, `app/views/admin/audit/index.html.erb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/admin_audit_spec.rb` (extend)

**Interfaces:**
- Produces: `record_admin_action(action, target = nil, details = nil)` and `acting_as_operator?(game)`, both private on `AdminAudit`. Tasks 4 uses both.

`AdminAction` carries one target, so a team-scoped intervention can name the game or the team but not both. `details` holds the team name alongside a `Game` target.

- [ ] **Step 1: Write the failing spec**

Append inside the existing top-level `describe` in `spec/requests/admin_audit_spec.rb`:

```ruby
  describe "the details column" do
    it "is nil for an action that records none" do
      sign_in(superadmin)
      post withdraw_game_path(game)

      expect(AdminAction.newest_first.first.details).to be_nil
    end

    it "renders on the log screen when present" do
      sign_in(superadmin)
      AdminAction.create!(:actor_id => superadmin.id, :action => "move_team",
                          :target_type => "Game", :target_id => game.id,
                          :target_label => game.name, :details => "Команда Кентавры")

      get admin_audit_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Команда Кентавры")
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_audit_spec.rb
```

Expected: FAIL — `unknown attribute 'details' for AdminAction`.

- [ ] **Step 3: Add the migration**

```bash
bin/rails generate migration AddDetailsToAdminActions
```

```ruby
class AddDetailsToAdminActions < ActiveRecord::Migration[8.0]
  def change
    # Nullable and nil for every action recorded so far. AdminAction carries a
    # single target, so a team-scoped intervention can name the game or the
    # team but not both; this holds the team alongside a Game target.
    add_column :admin_actions, :details, :string
  end
end
```

```bash
bin/rails db:migrate && bin/rails db:test:prepare
```

- [ ] **Step 4: Extend the concern**

In `app/controllers/concerns/admin_audit.rb`, change the method and add the operator test:

```ruby
  def record_admin_action(action, target = nil, details = nil)
    AdminAction.create!(
      :actor_id     => current_user&.id,
      :action       => action.to_s,
      :target_type  => target&.class&.name,
      :target_id    => target&.id,
      :target_label => AdminAction.label_for(target),
      :details      => details
    )
  end

  # Audited only when an operator acts on someone else's game. An author
  # acting on their own game is ordinary use, not an administrative act, and
  # recording it would bury the administrative entries under routine ones.
  #
  # Compares author_id directly rather than calling User#author_of?, which is
  # `game.author.id == self.id` and raises on a game whose author is missing.
  #
  # Lives here rather than on GamesController because InterventionsController
  # needs the same test; it takes the game explicitly so neither controller
  # depends on a particular instance variable being set.
  def acting_as_operator?(game)
    logged_in? && current_user.superadmin? && game.author_id != current_user.id
  end
```

- [ ] **Step 5: Update the existing call sites**

`app/controllers/games_controller.rb` currently defines a private `acting_as_operator?` taking no arguments and calls it in five places. Delete that private method and change every call to `acting_as_operator?(@game)`. In `delete`, the call is captured into a local *before* `@game.destroy` — keep that ordering, only change the argument.

Find them all before editing:

```bash
grep -n "acting_as_operator?" app/controllers/games_controller.rb
```

- [ ] **Step 6: Render `details` on the log screen**

In `app/views/admin/audit/index.html.erb`, add a fifth header cell and a fifth body cell:

```erb
    <th><%= t("admin.audit.index.details") %></th>
```

```erb
      <%# Free text captured at write time -- a team name, typically. Blank
          for every action that has no second subject. %>
      <td><%= entry.details %></td>
```

- [ ] **Step 7: Add the key to all four locale files**

`config/locales/ru.yml`, under `admin: audit: index:`:

```yaml
        details: "Подробности"
```

`config/locales/en.yml`, same position:

```yaml
        details: "Details"
```

Add the same key to `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 8: Run the specs, then both gates**

```bash
bundle exec rspec spec/requests/admin_audit_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **585 examples** (583 + 2), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps. The existing audit examples exercise every `acting_as_operator?` call site you changed — if any of them fail, a call site was missed.

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb app/controllers/concerns/admin_audit.rb app/controllers/games_controller.rb app/views/admin/audit config/locales spec/requests/admin_audit_spec.rb
git commit -m "Record a second subject on an audited action, and share the operator test"
```

---

### Task 2: The three team-scoped interventions

**Files:**
- Modify: `app/models/game_passing.rb`
- Test: `spec/models/game_passing/interventions_spec.rb`

**Interfaces:**
- Produces: `GamePassing#move_to_level!(level)`, `#reinstate!`, `#reset_level_clock!`. All raise `ArgumentError` when refused. Task 4 calls them and rescues that.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/game_passing/interventions_spec.rb
require "rails_helper"

describe GamePassing, "interventions" do
  let(:game)     { create_game }
  let(:first)    { create_level(:game => game) }
  let(:second)   { create_level(:game => game) }
  let(:passing)  { create_game_passing(:level => first) }

  describe "#move_to_level!" do
    it "puts the team on the level, with a fresh clock and no answers carried over" do
      passing.update!(:answered_questions => [ create_question(:level => first) ])
      passing.update_column(:current_level_entered_at, 3.hours.ago)

      passing.move_to_level!(second)

      passing.reload
      expect(passing.current_level).to eq(second)
      expect(passing.answered_questions).to be_empty
      expect(passing.current_level_entered_at).to be_within(5.seconds).of(Time.now)
    end

    # A team standing on a level is by definition not finished. Leaving
    # finished_at set on a team that is visibly mid-level is exactly the
    # contradictory row the whole design exists to prevent.
    it "un-finishes a team that had finished" do
      passing.update!(:finished_at => 1.hour.ago, :status => "ended")

      passing.move_to_level!(second)

      expect(passing.reload.finished_at).to be_nil
      expect(passing.status).to be_nil
    end

    it "un-exits a team that had quit" do
      passing.exit!

      passing.move_to_level!(second)

      expect(passing.reload.exited?).to be false
      expect(passing.finished_at).to be_nil
    end

    # Nothing else in the app would stop this, and the result is a passing
    # whose current_level belongs to a game it is not playing.
    it "refuses a level from another game" do
      other = create_level(:game => create_game)

      expect { passing.move_to_level!(other) }.to raise_error(ArgumentError)
      expect(passing.reload.current_level).to eq(first)
    end
  end

  describe "#reinstate!" do
    it "returns an exited team to play" do
      passing.exit!

      passing.reinstate!

      passing.reload
      expect(passing.exited?).to be false
      expect(passing.finished_at).to be_nil
      expect(passing.status).to be_nil
    end

    # exit! leaves current_level_entered_at untouched, so a team that quit an
    # hour ago carries an hour-old clock. Reinstating without the reset fires
    # every hint on that level the moment they reload -- a bigger unfairness
    # than the one the rescue was for.
    it "resets the level clock" do
      passing.update_column(:current_level_entered_at, 2.hours.ago)
      passing.exit!

      passing.reinstate!

      expect(passing.reload.current_level_entered_at).to be_within(5.seconds).of(Time.now)
    end
  end

  describe "#reset_level_clock!" do
    it "restarts the countdown" do
      passing.update_column(:current_level_entered_at, 90.minutes.ago)

      passing.reset_level_clock!

      expect(passing.reload.current_level_entered_at).to be_within(5.seconds).of(Time.now)
    end

    it "refuses a finished team, which has no live countdown" do
      passing.update!(:finished_at => Time.now)

      expect { passing.reset_level_clock! }.to raise_error(ArgumentError)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game_passing/interventions_spec.rb
```

Expected: FAIL — `undefined method 'move_to_level!'`.

- [ ] **Step 3: Implement the three methods**

In `app/models/game_passing.rb`, in the public section below `end!`:

```ruby
  # Operator interventions. Each leaves the record in a state ordinary
  # gameplay could also have produced -- that is the constraint the whole
  # feature is built on, and the reason there is no generic state editor.
  # Refusals raise ArgumentError; InterventionsController rescues it.

  def move_to_level!(level)
    raise ArgumentError, "level belongs to another game" unless level.game_id == self.game_id

    self.current_level = level
    self.answered_questions = []
    self.current_level_entered_at = Time.now
    # A team standing on a level is not finished. Clearing these here is what
    # keeps a moved team from being simultaneously mid-level and finished.
    self.finished_at = nil
    self.status = nil
    save!
  end

  def reinstate!
    # exit! leaves the entry clock alone, so without this reset a team that
    # quit an hour ago returns to a level with every hint already elapsed.
    self.current_level_entered_at = Time.now
    self.finished_at = nil
    self.status = nil
    save!
  end

  def reset_level_clock!
    raise ArgumentError, "team has finished" if self.finished?

    self.current_level_entered_at = Time.now
    save!
  end
```

- [ ] **Step 4: Run the spec, then both gates**

```bash
bundle exec rspec spec/models/game_passing/interventions_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: 8 examples pass; **593 examples** (585 + 8), 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/models/game_passing.rb spec/models/game_passing/interventions_spec.rb
git commit -m "Add the three team-scoped live interventions"
```

---

### Task 3: Pause, resume, and the frozen clock

**Files:**
- Create: `db/migrate/<ts>_add_paused_at_to_games.rb`
- Modify: `app/models/game.rb`, `app/models/game_passing.rb`, `app/models/hint.rb`, `app/controllers/game_passings_controller.rb`
- Test: `spec/models/game/pausing_spec.rb`

**Interfaces:**
- Produces: `Game#paused?`, `Game#pause!`, `Game#resume!` (both raise `ArgumentError` when refused); `GamePassing#effective_now`; `Hint#ready_to_show?(entered_at, now = Time.now)` and `Hint#available_in(entered_at, now = Time.now)`. Task 4 calls `pause!`/`resume!`; Task 5 reads `paused?`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/game/pausing_spec.rb
require "rails_helper"

describe Game, "pausing" do
  # starts_at in the past is what makes this a LIVE game -- and also what makes
  # it fail its own validations (game_starts_in_the_future), which is why
  # pause!/resume! must use update_column.
  let(:game)    { g = create_game; g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }

  it "starts unpaused" do
    expect(game.paused?).to be false
  end

  it "pauses and resumes" do
    game.pause!
    expect(game.reload.paused?).to be true

    game.resume!
    expect(game.reload.paused?).to be false
  end

  # The trap this whole design had to route around: a running game does not
  # pass its own validations, so update! would raise RecordInvalid on exactly
  # the games pause exists for, and update would fail silently.
  it "pauses a game whose start time is in the past" do
    expect(game.valid?).to be false

    expect { game.pause! }.not_to raise_error
    expect(game.reload.paused_at).not_to be_nil
  end

  it "refuses to pause twice, or to resume a game that is not paused" do
    expect { game.resume! }.to raise_error(ArgumentError)

    game.pause!
    expect { game.pause! }.to raise_error(ArgumentError)
  end

  describe "the countdown" do
    # The property the whole feature turns on: a team resumes with exactly the
    # countdown it had when play stopped.
    it "gives back the same remaining time after a pause" do
      passing.update_column(:current_level_entered_at, 10.minutes.ago)

      game.pause!
      paused_remaining = Time.now - passing.reload.current_level_entered_at

      travel_to(30.minutes.from_now) do
        game.reload.resume!
        resumed_remaining = Time.now - passing.reload.current_level_entered_at

        expect(resumed_remaining).to be_within(5.seconds).of(paused_remaining)
      end
    end

    it "leaves finished teams alone" do
      passing.update!(:finished_at => Time.now)
      entered_at = passing.reload.current_level_entered_at

      game.pause!
      travel_to(20.minutes.from_now) { game.reload.resume! }

      expect(passing.reload.current_level_entered_at).to eq(entered_at)
    end
  end

  describe "frozen hints" do
    # Not merely uncounted afterwards: level_hint_updater.js polls
    # get_current_level_tip throughout the pause, so a hint that becomes
    # visible DURING the hold has already been read by the time resume shifts
    # the clock back. This is the failure effective_now exists to prevent, and
    # it is invisible to any test that only inspects state after resuming.
    it "does not reveal a new hint while the game is paused" do
      create_hint(:level => level, :delay => 20 * 60)
      passing.update_column(:current_level_entered_at, 5.minutes.ago)

      expect(passing.reload.hints_to_show).to be_empty

      game.pause!

      travel_to(1.hour.from_now) do
        expect(passing.reload.hints_to_show).to be_empty
      end
    end

    it "reveals it normally when the game is not paused" do
      create_hint(:level => level, :delay => 20 * 60)
      passing.update_column(:current_level_entered_at, 5.minutes.ago)

      travel_to(1.hour.from_now) do
        expect(passing.reload.hints_to_show.size).to eq(1)
      end
    end
  end
end
```

`travel_to` comes from `ActiveSupport::Testing::TimeHelpers`. If `spec/rails_helper.rb` does not already include it, add `config.include ActiveSupport::Testing::TimeHelpers` inside the `RSpec.configure` block — check first, and say in your report which you did.

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/pausing_spec.rb
```

Expected: FAIL — `undefined method 'paused?'`.

- [ ] **Step 3: Add the migration**

```bash
bin/rails generate migration AddPausedAtToGames
```

```ruby
class AddPausedAtToGames < ActiveRecord::Migration[8.0]
  def change
    # Nullable: nil means "not paused", which is every game that exists.
    # Durable rather than in-memory, so a deploy or a crash mid-pause leaves
    # the game paused and resume works whenever someone reaches it.
    add_column :games, :paused_at, :datetime
  end
end
```

```bash
bin/rails db:migrate && bin/rails db:test:prepare
```

- [ ] **Step 4: Add the `Game` methods**

In `app/models/game.rb`, beside `editing_locked?`:

```ruby
  def paused?
    self.paused_at.present?
  end

  # update_column, not update!, and this is not a style preference: a running
  # game does not pass its own validations. game_starts_in_the_future adds an
  # error whenever author_finished_at is nil and starts_at is in the past --
  # true of every game being played. update! would raise RecordInvalid on
  # exactly the games pause exists for, and update would fail silently, the
  # same trap that makes reserve_place_for_team! stop enforcing
  # max_team_number once a game starts.
  def pause!
    raise ArgumentError, "already paused" if self.paused?

    update_column(:paused_at, Time.now)
  end

  # Shifting current_level_entered_at forward by the held duration is exactly
  # equivalent to not counting the paused interval, because that column is the
  # only input to every countdown.
  #
  # Transactional deliberately -- and this is the OPPOSITE call from the audit
  # write in AdminAudit, which is kept out of its action's transaction so a
  # logging failure cannot block an administrative change. Here the shift IS
  # the operation: a half-applied resume would hand some teams their countdown
  # back and silently rob others, and nothing downstream could tell.
  def resume!
    raise ArgumentError, "not paused" unless self.paused?

    transaction do
      held = Time.now - self.paused_at
      # finished_at excludes both finished and exited teams; neither has a
      # running clock. update_column because this is a mechanical bulk shift.
      GamePassing.of_game(self).where(:finished_at => nil).find_each do |gp|
        gp.update_column(:current_level_entered_at, gp.current_level_entered_at + held)
      end
      update_column(:paused_at, nil)
    end
  end
```

- [ ] **Step 5: Give `Hint` an explicit clock**

In `app/models/hint.rb`, both methods gain a defaulted second argument, so no existing caller changes:

```ruby
  def ready_to_show?(current_level_entered_at, now = Time.now)
    seconds_passed = now - current_level_entered_at
    seconds_passed >= self.delay
  end

  def available_in(current_level_entered_at, now = Time.now)
    (current_level_entered_at - now).to_i + self.delay
  end
```

- [ ] **Step 6: Freeze the clock in `GamePassing`**

In `app/models/game_passing.rb`, add `effective_now` and route the three time-reading methods through it:

```ruby
  # The clock every countdown is measured against. While a game is paused this
  # is the instant it was paused, so hints_to_show, upcoming_hints and
  # time_at_level all freeze together -- and get_current_level_tip returns an
  # unchanging state to every poll without knowing pausing exists.
  #
  # One concept instead of a filter on the tip endpoint that every future hint
  # code path would have to remember.
  def effective_now
    self.game&.paused_at || Time.now
  end

  def hints_to_show
    now = effective_now
    current_level.hints.select { |hint| hint.ready_to_show?(current_level_entered_at, now) }
  end

  def upcoming_hints
    now = effective_now
    current_level.hints.select { |hint| !hint.ready_to_show?(current_level_entered_at, now) }
  end

  def time_at_level
    difference = effective_now - self.current_level_entered_at
    hours, minutes, seconds = seconds_fraction_to_time(difference)
    "%02d:%02d:%02d" % [hours, minutes, seconds]
  end
```

- [ ] **Step 7: Freeze the JSON poller too**

`GamePassingsController#get_current_level_tip` calls `next_hint&.available_in(@game_passing.current_level_entered_at)`. Pass the frozen clock:

```ruby
    next_hint&.available_in(@game_passing.current_level_entered_at, @game_passing.effective_now)
```

- [ ] **Step 8: Run the spec, then both gates**

```bash
bundle exec rspec spec/models/game/pausing_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: 8 examples pass; **601 examples** (593 + 8), 0 failures, 6 pending; cucumber unchanged at 234 scenarios. Cucumber exercises hints heavily — if it moves, the defaulted `now` argument is not defaulting where you think.

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb app/models/game.rb app/models/game_passing.rb app/models/hint.rb app/controllers/game_passings_controller.rb spec/models/game/pausing_spec.rb
git commit -m "Pause and resume a running game with the countdowns frozen"
```

---

### Task 4: The interventions controller

**Files:**
- Create: `app/controllers/interventions_controller.rb`
- Modify: `app/controllers/concerns/security_filters.rb`, `config/routes.rb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/interventions_spec.rb`

**Interfaces:**
- Consumes: Task 1's `record_admin_action(action, target, details)` and `acting_as_operator?(game)`; Task 2's three `GamePassing` methods; Task 3's `pause!`/`resume!`.
- Produces: routes `pause_game_path`, `resume_game_path`, `move_team_path`, `reinstate_team_path`, `reset_team_clock_path`; `SecurityFilters#ensure_game_is_live`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/interventions_spec.rb
require "rails_helper"

describe "live-game interventions", type: :request do
  let(:author)     { create_user }
  let(:stranger)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  let(:game)    { g = create_game(:author => author); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "authorization" do
    it "refuses an anonymous visitor" do
      post pause_game_path(game)
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(login_path)
    end

    it "refuses a different author" do
      sign_in(stranger)
      post pause_game_path(game)
      expect(response).to have_http_status(:unauthorized)
      expect(game.reload.paused?).to be false
    end

    it "allows the game's own author" do
      sign_in(author)
      post pause_game_path(game)
      expect(game.reload.paused?).to be true
    end

    it "allows a superadmin on someone else's game" do
      sign_in(superadmin)
      post pause_game_path(game)
      expect(game.reload.paused?).to be true
    end

    # The lock exists so an operator can stop an author touching a game under
    # investigation. Live intervention has to be inside it, or the lock is
    # trivially sidestepped.
    it "refuses a locked game to its author but not to a superadmin" do
      game.update_column(:editing_locked_at, Time.now)

      sign_in(author)
      post pause_game_path(game)
      expect(response).to have_http_status(:unauthorized)
      expect(game.reload.paused?).to be false

      sign_in(superadmin)
      post pause_game_path(game)
      expect(game.reload.paused?).to be true
    end

    it "refuses a game that has not started" do
      future = create_game(:author => author)
      sign_in(author)

      post pause_game_path(future)

      expect(response).to have_http_status(:unauthorized)
      expect(future.reload.paused?).to be false
    end

    it "refuses a game the author has already finished" do
      game.update_column(:author_finished_at, Time.now)
      sign_in(author)

      post pause_game_path(game)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # A guard that treated `paused?` as not-live would put resume behind a
  # condition only resume can clear -- an action no request could ever reach.
  # Sub-project B shipped exactly that defect, and its test passed while
  # measuring a different guard. This one drives resume through the controller
  # rather than calling the model, which is the only way to see it.
  describe "reachability while paused" do
    it "reaches resume on a paused game" do
      sign_in(author)
      post pause_game_path(game)

      post resume_game_path(game)

      expect(response).to have_http_status(:found)
      expect(game.reload.paused?).to be false
    end

    it "reaches the team interventions on a paused game" do
      passing
      sign_in(author)
      post pause_game_path(game)

      post reset_team_clock_path(:game_id => game.id, :team_id => passing.team_id)

      expect(response).to have_http_status(:found)
    end
  end

  describe "the team interventions" do
    before { sign_in(author) }

    it "moves a team to a level" do
      second = create_level(:game => game)
      passing

      post move_team_path(:game_id => game.id, :team_id => passing.team_id),
           :params => { :level_id => second.id }

      expect(passing.reload.current_level).to eq(second)
    end

    it "refuses a level from another game without changing anything" do
      other = create_level(:game => create_game)
      passing

      post move_team_path(:game_id => game.id, :team_id => passing.team_id),
           :params => { :level_id => other.id }

      expect(passing.reload.current_level).to eq(level)
      expect(response).to have_http_status(:found)
    end

    it "reinstates a team that quit" do
      passing.exit!

      post reinstate_team_path(:game_id => game.id, :team_id => passing.team_id)

      expect(passing.reload.exited?).to be false
    end
  end

  describe "auditing" do
    it "records a superadmin acting on someone else's game, naming the team" do
      passing
      sign_in(superadmin)

      expect {
        post reset_team_clock_path(:game_id => game.id, :team_id => passing.team_id)
      }.to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("reset_clock")
      expect(entry.target_id).to eq(game.id)
      expect(entry.details).to eq(passing.team.name)
    end

    it "records a pause" do
      sign_in(superadmin)
      expect { post pause_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("pause")
    end

    # B's rule: an author acting on their own game is ordinary use.
    it "records nothing for the author of the game" do
      sign_in(author)
      expect { post pause_game_path(game) }.not_to change { AdminAction.count }
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/interventions_spec.rb
```

Expected: FAIL — undefined route helper `pause_game_path`.

- [ ] **Step 3: Add the filter**

In `app/controllers/concerns/security_filters.rb`, below `ensure_editing_not_locked`:

```ruby
  # Interventions only make sense on a game that is actually being played.
  #
  # Two exemptions are load-bearing. A PAUSED game is live: treating it
  # otherwise would put #resume behind a condition only #resume can clear, an
  # action no request could ever reach. A game in TEST mode is live: is_testing
  # games skip ensure_game_is_started throughout GamePassingsController, and an
  # author testing their own game is exactly who wants to move a team between
  # levels.
  def ensure_game_is_live
    return if @game.is_testing?

    live = @game.started? && !@game.draft? && !@game.withdrawn? && !@game.author_finished?
    raise Authentication::Unauthorized, t("errors.game_is_not_live") unless live
  end
```

- [ ] **Step 4: Add the routes**

In `config/routes.rb`, beside the other game routes:

```ruby
  # Live-game interventions. Team-scoped ones carry both ids because the
  # operator acts on one team's passing within one game.
  post "/games/:game_id/pause",  to: "interventions#pause",  as: :pause_game
  post "/games/:game_id/resume", to: "interventions#resume", as: :resume_game
  post "/games/:game_id/teams/:team_id/move",        to: "interventions#move",        as: :move_team
  post "/games/:game_id/teams/:team_id/reinstate",   to: "interventions#reinstate",   as: :reinstate_team
  post "/games/:game_id/teams/:team_id/reset_clock", to: "interventions#reset_clock", as: :reset_team_clock
```

- [ ] **Step 5: Write the controller**

```ruby
# app/controllers/interventions_controller.rb
#
# Operator actions on a game that is actually being played. Every action calls
# a named model method and redirects back to the stats page -- nothing here
# writes a column directly, which is what keeps a tired operator from producing
# a passing the model has no path to.
class InterventionsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :find_game
  # ensure_author already means "the author, or any superadmin", and
  # ensure_editing_not_locked already exempts superadmins -- together they give
  # this feature's whole authorization rule with no new concept.
  before_action :ensure_author
  before_action :ensure_editing_not_locked
  before_action :ensure_game_is_live
  before_action :find_game_passing, only: [ :move, :reinstate, :reset_clock ]

  # The model methods raise ArgumentError when they refuse. One rescue covers
  # every refusal, so no action has to duplicate the check its model already does.
  rescue_from ArgumentError, with: :refused

  def pause
    @game.pause!
    audit("pause")
    back_to_stats(t("interventions.paused_notice"))
  end

  def resume
    @game.resume!
    audit("resume")
    back_to_stats(t("interventions.resumed_notice"))
  end

  def move
    level = Level.find(params[:level_id])
    @game_passing.move_to_level!(level)
    audit("move_team", @game_passing.team.name)
    back_to_stats(t("interventions.moved_notice"))
  end

  def reinstate
    @game_passing.reinstate!
    audit("reinstate_team", @game_passing.team.name)
    back_to_stats(t("interventions.reinstated_notice"))
  end

  def reset_clock
    @game_passing.reset_level_clock!
    audit("reset_clock", @game_passing.team.name)
    back_to_stats(t("interventions.clock_reset_notice"))
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_game_passing
    @game_passing = GamePassing.of_game(@game).of_team(params[:team_id]).first
    raise ActiveRecord::RecordNotFound unless @game_passing
  end

  # Recorded after the change lands, and only for an operator acting on someone
  # else's game -- sub-project B's rule. The target is the game; `details`
  # carries the team, which a single-target row could not otherwise hold.
  def audit(action, details = nil)
    record_admin_action(action, @game, details) if acting_as_operator?(@game)
  end

  def back_to_stats(notice)
    redirect_to game_stats_path(:index, @game), :notice => notice
  end

  def refused(exception)
    redirect_to game_stats_path(:index, @game), :alert => t("interventions.refused")
  end
end
```

- [ ] **Step 6: Add the chrome keys to all four locale files**

`config/locales/ru.yml` — under `errors:`:

```yaml
  game_is_not_live: "Игра сейчас не идёт"
```

and a new top-level `interventions:` section:

```yaml
  interventions:
    paused_notice: "Игра приостановлена"
    resumed_notice: "Игра продолжается"
    moved_notice: "Команда переведена на другой уровень"
    reinstated_notice: "Команда возвращена в игру"
    clock_reset_notice: "Отсчёт времени на уровне сброшен"
    refused: "Это действие сейчас невозможно"
```

`config/locales/en.yml`, same positions:

```yaml
  game_is_not_live: "This game is not currently running"
```

```yaml
  interventions:
    paused_notice: "Game paused"
    resumed_notice: "Game resumed"
    moved_notice: "Team moved to another level"
    reinstated_notice: "Team returned to the game"
    clock_reset_notice: "The level countdown has been reset"
    refused: "That action is not possible right now"
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values.

- [ ] **Step 7: Run the specs, then both gates**

```bash
bundle exec rspec spec/requests/interventions_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: 15 examples pass; **616 examples** (601 + 15), 0 failures, 6 pending; cucumber unchanged; `All is good!`.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/interventions_controller.rb app/controllers/concerns/security_filters.rb config/routes.rb config/locales spec/requests/interventions_spec.rb
git commit -m "Add the live-game interventions controller"
```

---

### Task 5: What a player can and cannot do while paused

**Files:**
- Modify: `app/controllers/game_passings_controller.rb`, `app/views/game_passings/show_current_level.html.erb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/paused_gameplay_spec.rb`

**Interfaces:**
- Consumes: Task 3's `Game#paused?`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/paused_gameplay_spec.rb
require "rails_helper"

describe "playing a paused game", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game, :correct_answer => "правильно") }
  let(:passing) { create_game_passing(:level => level) }
  let(:player)  { u = create_user; u.update!(:team => passing.team); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    passing
    sign_in(player)
  end

  it "still shows the player their level, with the paused notice" do
    game.pause!

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("game_passings.paused"))
    expect(response.body).to include(level.name)
  end

  # A paused game is a normal temporary state, not an authorization failure --
  # rendering it as a 401 would be both confusing and untrue.
  it "refuses an answer with a notice rather than a 401" do
    game.pause!

    post post_answer_path(:game_id => game.id), :params => { :answer => "правильно" }

    expect(response).not_to have_http_status(:unauthorized)
    expect(passing.reload.current_level).to eq(level)
  end

  it "accepts the same answer once the game resumes" do
    game.pause!
    game.reload.resume!

    post post_answer_path(:game_id => game.id), :params => { :answer => "правильно" }

    expect(passing.reload.current_level).not_to eq(level)
  end

  it "refuses to let a team quit while paused" do
    game.pause!

    get exit_game_path(:game_id => game.id)

    expect(passing.reload.exited?).to be false
  end
end
```

Check `create_level`'s handling of `:correct_answer` before relying on it — `Level#correct_answer=` builds a question. If a level built that way does not produce a matchable answer through `check_answer!`, build the question explicitly with `create_question` instead and say so in your report.

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/paused_gameplay_spec.rb
```

Expected: FAIL — the paused notice is not in the body.

- [ ] **Step 3: Refuse play while paused**

In `app/controllers/game_passings_controller.rb`, add to the filter list:

```ruby
  before_action :ensure_game_not_paused, only: [ :post_answer, :exit_game ]
```

and the filter itself, in the private section beside the other `ensure_*` methods:

```ruby
  # Deliberately NOT an Authentication::Unauthorized like its neighbours here.
  # A paused game is a normal temporary state, not an authorization failure,
  # and telling a player they are not allowed to play their own game would be
  # both confusing and untrue. show_current_level is not in this list: the
  # player keeps seeing their level with a banner over it.
  def ensure_game_not_paused
    return unless @game.paused?

    redirect_to show_current_level_path(:game_id => @game.id),
                :alert => t("game_passings.paused")
  end
```

- [ ] **Step 4: Add the banner**

At the top of `app/views/game_passings/show_current_level.html.erb`, before the existing content:

```erb
<% if @game.paused? %>
  <p class="game-paused"><%= t("game_passings.paused") %></p>
<% end %>
```

- [ ] **Step 5: Add the key to all four locale files**

`config/locales/ru.yml`, under `game_passings:`:

```yaml
    paused: "Игра приостановлена организатором. Оставайтесь на месте и ждите продолжения."
```

`config/locales/en.yml`:

```yaml
    paused: "The organiser has paused the game. Stay where you are and wait for it to resume."
```

Add the same key to `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 6: Run the specs, then both gates**

```bash
bundle exec rspec spec/requests/paused_gameplay_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: 4 examples pass; **620 examples** (616 + 4), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps. Cucumber plays games constantly — every one of those games has `paused_at` nil, so the filter must be invisible to them.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/game_passings_controller.rb app/views/game_passings/show_current_level.html.erb config/locales spec/requests/paused_gameplay_spec.rb
git commit -m "Hold play while a game is paused, without calling it an authorization failure"
```

---

### Task 6: The controls on the stats page

**Files:**
- Create: `app/views/game_passings/_intervention_controls.html.erb`
- Modify: `app/views/game_passings/index.html.erb`, `app/controllers/game_passings_controller.rb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/interventions_spec.rb` (extend)

**Interfaces:**
- Consumes: Task 4's five route helpers; Task 3's `Game#paused?`.

`GamePassingsController#index` already runs `ensure_author`, so it is already reachable by exactly the people who may intervene. It needs `@levels` for the move control.

- [ ] **Step 1: Write the failing spec**

Append inside the top-level `describe` in `spec/requests/interventions_spec.rb`:

```ruby
  describe "the stats page controls" do
    it "offers pause to the author of a running game" do
      passing
      sign_in(author)

      get game_stats_path(:index, game)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pause_game_path(game))
    end

    it "offers resume instead once the game is paused" do
      passing
      game.pause!
      sign_in(author)

      get game_stats_path(:index, game)

      expect(response.body).to include(resume_game_path(game))
      expect(response.body).not_to include(pause_game_path(game))
    end

    it "offers the team controls" do
      passing
      sign_in(author)

      get game_stats_path(:index, game)

      expect(response.body).to include(reset_team_clock_path(:game_id => game.id, :team_id => passing.team_id))
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/interventions_spec.rb -e "stats page controls"
```

Expected: FAIL — the body does not contain the pause path.

- [ ] **Step 3: Load the levels the move control needs**

In `GamePassingsController#index`:

```ruby
  def index
    @game_passings = GamePassing.of_game(@game)
    # For the move control on each row. Loaded once here rather than per row.
    @levels = Level.of_game(@game).order(:position)
  end
```

- [ ] **Step 4: Write the partial**

```erb
<%# app/views/game_passings/_intervention_controls.html.erb
    One team's row of operator controls. Every control posts to a named
    action -- there is deliberately no field that writes a column directly. %>
<td class="interventions">
  <%= form_with :url => move_team_path(:game_id => game_passing.game_id, :team_id => game_passing.team_id),
                :method => :post, :local => true do |f| %>
    <%# Level names are author-written content: rendered verbatim, never
        through t(). %>
    <%= f.select :level_id, levels.map { |level| [ level.name, level.id ] } %>
    <%= f.submit t("game_passings.index.move") %>
  <% end %>

  <% if game_passing.exited? %>
    <%= button_to t("game_passings.index.reinstate"),
                  reinstate_team_path(:game_id => game_passing.game_id, :team_id => game_passing.team_id),
                  :method => :post %>
  <% end %>

  <% unless game_passing.finished? %>
    <%= button_to t("game_passings.index.reset_clock"),
                  reset_team_clock_path(:game_id => game_passing.game_id, :team_id => game_passing.team_id),
                  :method => :post %>
  <% end %>
</td>
```

- [ ] **Step 5: Wire it into the stats page**

In `app/views/game_passings/index.html.erb`, add a header cell beside the existing ones:

```erb
      <th><%= t("game_passings.index.interventions") %></th>
```

render the partial as the last cell of each row, inside the existing `each`:

```erb
        <%= render "intervention_controls", :game_passing => game_passing, :levels => @levels %>
```

and put the pause control above the table:

```erb
<p class="game-control">
  <% if @game.paused? %>
    <%= t("game_passings.index.paused_since", :time => l(@game.paused_at, :format => :long)) %>
    <%= button_to t("game_passings.index.resume"), resume_game_path(@game), :method => :post %>
  <% else %>
    <%= button_to t("game_passings.index.pause"), pause_game_path(@game), :method => :post %>
  <% end %>
</p>
```

- [ ] **Step 6: Add the keys to all four locale files**

`config/locales/ru.yml`, under `game_passings: index:`:

```yaml
        interventions: "Вмешательство"
        move: "Перевести"
        reinstate: "Вернуть в игру"
        reset_clock: "Сбросить отсчёт"
        pause: "Приостановить игру"
        resume: "Продолжить игру"
        paused_since: "Игра приостановлена в %{time}."
```

`config/locales/en.yml`:

```yaml
        interventions: "Intervene"
        move: "Move"
        reinstate: "Return to the game"
        reset_clock: "Reset countdown"
        pause: "Pause the game"
        resume: "Resume the game"
        paused_since: "Paused at %{time}."
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values.

- [ ] **Step 7: Run the specs, then both gates and the autoloading check**

```bash
bundle exec rspec spec/requests/interventions_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: 18 examples in the interventions spec; **623 examples** (620 + 3), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps; `All is good!`.

- [ ] **Step 8: Commit**

```bash
git add app/views/game_passings app/controllers/game_passings_controller.rb config/locales spec/requests/interventions_spec.rb
git commit -m "Put the intervention controls on the stats page"
```

---

## Self-Review

**Spec coverage.** The three team-scoped interventions and their producible-state guarantees (Task 2); `move_to_level!` rejecting a cross-game level (Tasks 2, 4); pause/resume with the transactional shift and the `update_column` requirement (Task 3); the `effective_now` frozen clock across `hints_to_show`, `upcoming_hints`, `time_at_level` and the JSON poller (Task 3); hints frozen *during* a pause rather than only corrected afterwards (Task 3); `InterventionsController` with `ensure_author` + `ensure_editing_not_locked` + `ensure_game_is_live`, including the paused and `is_testing` exemptions (Task 4); the full authorization matrix asserted with specific statuses (Task 4); auditing under B's rule with `details` carrying the team (Tasks 1, 4); the player-facing banner and the refusal that is not a 401 (Task 5); controls on the stats page (Task 6); `Log` rows untouched throughout — no task writes one.

**Deliberately absent, per the spec:** log editing; results annotation; a generic state editor; a free-text pause reason; scheduled pause; the `exit!`/`finished_teams` standings bug. No task builds any of them.

**Placeholder scan.** No "TBD" or "add validation". Two steps ask the implementer to verify something before relying on it, each with a stated fallback: Task 3 Step 1 on whether `rails_helper.rb` already includes `TimeHelpers`, and Task 5 Step 1 on whether `create_level(:correct_answer => ...)` yields an answer `check_answer!` will match. Both are honest unknowns about existing code, not deferred decisions.

**Type consistency.** `record_admin_action(action, target = nil, details = nil)` is defined in Task 1 and called with all three arguments in Task 4. `acting_as_operator?(game)` is defined in Task 1, its old no-argument form removed in the same task, and called in Task 4. `move_to_level!(level)`, `reinstate!`, `reset_level_clock!` are defined in Task 2 and called in Task 4. `pause!`, `resume!`, `paused?`, `effective_now` are defined in Task 3 and used in Tasks 4, 5 and 6. `ready_to_show?(entered_at, now = Time.now)` and `available_in(entered_at, now = Time.now)` are defined once in Task 3 and called with two arguments only from `GamePassing` and the tip endpoint. Route helpers `pause_game_path`, `resume_game_path`, `move_team_path`, `reinstate_team_path`, `reset_team_clock_path` are introduced in Task 4 and reused unchanged in Task 6.

**One risk I want the reviewer looking at.** Task 3 changes `Hint#ready_to_show?` and `#available_in`, which the live gameplay path calls on every page load and every poll. The defaulted second argument means no existing caller changes — but "no existing caller changes" is exactly the kind of claim that is true until it isn't. Cucumber is the real check here: it plays games end to end with hints, so any movement in its 234 scenarios means the defaulting is not doing what this plan assumes.

**Running example counts.** 583 → 585 (T1) → 593 (T2) → 601 (T3) → 616 (T4) → 620 (T5) → 623 (T6). Cucumber stays at 234 scenarios / 2362 steps throughout; any change there is a regression, not a new feature.
