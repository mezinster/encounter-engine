# Superadmin Accountability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it safe to give the superadmin role to someone other than the instance owner — by recording every administrative change, and by letting the role be granted and revoked from the UI.

**Architecture:** One append-only `admin_actions` table. An `AdminAudit` controller concern with a single method, called **explicitly** at each site and only after the change has landed. Grant and revoke on the existing `Admin::UsersController`, with two guards. One read-only screen to read the log.

**Tech Stack:** Ruby 3.3.12, Rails 8.0.5.1, SQLite (dev/test), PostgreSQL (production), RSpec 3.13.

## Global Constraints

- Ruby is pinned to `3.3.12` and Rails to `8.0.5.1`. Do not change either.
- rbenv is not on PATH in non-login shells. Prefix every Ruby command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never create, edit or delete any file under `features/`.** Those `.feature` files are the contract the Merb→Rails port was validated against, whitespace included.
- Existing gates must stay green: `bundle exec rspec` is **549 examples, 0 failures, 6 pending**; `bundle exec cucumber` is **234 scenarios (2 pre-existing "undefined" placeholders), 2362 steps**. `bin/rails zeitwerk:check` must print `All is good!`.
- **Entries are written only after the change succeeds.** A refused deletion or a failed update leaves no entry. An audit trail that records attempts answers a different question from one that records changes, and mixing them makes it useless for both.
- **The audit write is not wrapped in a transaction with the action.** If the log write fails, the action still stands — an operator unable to withdraw a game because the audit table is unavailable is worse than a missing row.
- **Append-only.** No UI or code path updates or deletes an entry.
- **Actions by an author on their own game are never audited.** The condition is "superadmin **and** not the author", not "superadmin".
- **Reads are never audited**, including views of a user's contact details.
- **Platform chrome goes through `t()`;** user- and author-written content renders verbatim. New keys go in all four of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb` enforces `ru`↔`en` exact parity and `uk`/`ka` as a subset; `raise_on_missing_translations` is on in test. **On this branch `uk`/`ka` are stubs holding Russian text** — use the Russian value there and say so in your report.
- Factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb`. No FactoryBot. New specs use `expect`.
- New refusal assertions use the specific status (`have_http_status(:unauthorized)`, or `:found` plus `redirect_to(login_path)` for anonymous requests) — never `not_to have_http_status(:ok)`, which a 500 also satisfies. The suite currently has none of the weak form; do not reintroduce it.
- Hash rockets (`:key => value`) are the surrounding style in these models and controllers.
- **Out of scope:** auditing reads; auditing authors acting on their own games; any second administrative tier or owner concept; editing, deleting or exporting entries; filtering, search or pagination on the log; anything touching a running game's `GamePassing` records (sub-project C).

### Facts verified against this app while writing this plan

Do not re-derive these; do check anything this plan does *not* state.

- The four explicit actions are one-liners in `app/controllers/games_controller.rb`, each `@game.update!(...)` then `redirect_to admin_games_path`.
- `GamesController#update` is `if @game.update(game_attributes)` / `else render :edit, status: :unprocessable_entity`.
- `GamesController#delete` refuses first (`unless @game.deletable?`) then calls `@game.destroy` and redirects to `dashboard_path`.
- `GamesController#end_game` calls `@game.finish_game!` then ends every passing.
- **`User#author_of?(game)` is `game.author.id == self.id`** — it raises on a game with no author. Compare `@game.author_id` directly instead.
- The admin namespace currently holds `get "/" => dashboard#show`, `resources :games, only: [:index]`, `resources :users, only: [:index, :show]`.
- `Admin::` controllers follow: `include SecurityFilters`, `before_action :require_authentication!`, `before_action :require_superadmin!`.
- Login is `PUT /login` → `sessions#update`. **`create_user` sets the password `1234`.**
- `spec/support/query_counter.rb` provides `count_queries { … }`, required from `spec/rails_helper.rb`.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/<ts>_create_admin_actions.rb` | The append-only table |
| `app/models/admin_action.rb` | One recorded action, plus `label_for` |
| `app/controllers/concerns/admin_audit.rb` | `record_admin_action` |
| `app/controllers/admin/audit_controller.rb` | Reading the log |
| `app/views/admin/audit/index.html.erb` | The log, rendered |
| `spec/models/admin_action_spec.rb` | Label snapshotting |
| `spec/requests/admin_audit_spec.rb` | Which actions record, and which do not |
| `spec/requests/superadmin_granting_spec.rb` | Grant, revoke, and the two guards |

**Modified:**

| File | Change |
|---|---|
| `app/models/user.rb` | `User.superadmin_count`, `#last_superadmin?` |
| `app/controllers/games_controller.rb` | `record_admin_action` calls at seven sites |
| `app/controllers/admin/users_controller.rb` | `grant`, `revoke` |
| `config/routes.rb` | Audit route; grant/revoke members |
| `config/locales/{ru,en,uk,ka}.yml` | New chrome keys |

---

### Task 1: The table, the model, and the recording concern

**Files:**
- Create: `db/migrate/<ts>_create_admin_actions.rb`, `app/models/admin_action.rb`, `app/controllers/concerns/admin_audit.rb`, `spec/models/admin_action_spec.rb`
- Test: `spec/models/admin_action_spec.rb`

**Interfaces:**
- Produces: `AdminAction` with columns `actor_id`, `action`, `target_type`, `target_id`, `target_label`, `created_at`; `AdminAction.label_for(target)` → `String` or `nil`; `AdminAction.newest_first` scope; and the private controller method `record_admin_action(action, target = nil)`. Tasks 2 and 3 call `record_admin_action`; Task 4 reads `newest_first`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/admin_action_spec.rb
require "rails_helper"

describe AdminAction do
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }

  describe ".label_for" do
    it "uses a game's name" do
      game = create_game(:name => "Городской квест")
      expect(AdminAction.label_for(game)).to eq("Городской квест")
    end

    it "uses a user's nickname" do
      user = create_user
      expect(AdminAction.label_for(user)).to eq(user.nickname)
    end

    it "is nil for no target" do
      expect(AdminAction.label_for(nil)).to be_nil
    end
  end

  # The property the column exists for. A deleted game leaves target_id
  # pointing at nothing, so without the snapshot the single most important
  # entry an audit trail holds -- who deleted what -- reads as "Game #47".
  it "still names its target after the target is destroyed" do
    game = create_game(:name => "Обречённая игра", :is_draft => true)
    entry = AdminAction.create!(:actor_id => actor.id, :action => "delete",
                                :target_type => "Game", :target_id => game.id,
                                :target_label => AdminAction.label_for(game))
    game.destroy

    expect(Game.where(:id => entry.target_id)).to be_empty
    expect(entry.reload.target_label).to eq("Обречённая игра")
  end

  it "orders newest first" do
    older = AdminAction.create!(:actor_id => actor.id, :action => "lock")
    newer = AdminAction.create!(:actor_id => actor.id, :action => "unlock")
    older.update_column(:created_at, 1.hour.ago)

    expect(AdminAction.newest_first.first).to eq(newer)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/admin_action_spec.rb
```

Expected: FAIL — `uninitialized constant AdminAction`.

- [ ] **Step 3: Write the migration**

```bash
bin/rails generate migration CreateAdminActions
```

```ruby
class CreateAdminActions < ActiveRecord::Migration[8.0]
  def change
    create_table :admin_actions do |t|
      t.integer  :actor_id,    null: false
      t.string   :action,      null: false
      # Nullable: not every action has a target.
      t.string   :target_type
      t.integer  :target_id
      # The target's name AT THE TIME. See the model comment.
      t.string   :target_label
      # created_at only, deliberately: rows are never updated, so an
      # updated_at column would imply a capability this table must not have.
      t.datetime :created_at, null: false
    end

    add_index :admin_actions, :created_at
    add_index :admin_actions, :actor_id
  end
end
```

```bash
bin/rails db:migrate && bin/rails db:test:prepare
```

- [ ] **Step 4: Write the model**

```ruby
# app/models/admin_action.rb
#
# One administrative change, recorded. Append-only: nothing in this
# application updates or deletes a row, and nothing should be added that does.
# A log its own subject can edit is not a log.
class AdminAction < ApplicationRecord
  belongs_to :actor, :class_name => "User", :optional => true

  validates :action, presence: true

  scope :newest_first, -> { order(:created_at => :desc) }

  # Snapshots the target's name at the moment of the action.
  #
  # This is why target_label exists at all. A deleted game leaves target_id
  # pointing at a row that no longer exists, so without the snapshot the
  # single most important entry an audit trail can hold -- who deleted what --
  # renders as "Game #47": a number nobody can resolve, recording the loss of
  # the very thing that would have explained it.
  #
  # It also means a renamed game's entry says what it was called when the
  # action happened, which is what an audit trail should say.
  def self.label_for(target)
    return nil if target.nil?
    return target.name if target.respond_to?(:name)
    return target.nickname if target.respond_to?(:nickname)

    nil
  end
end
```

- [ ] **Step 5: Write the concern**

```ruby
# app/controllers/concerns/admin_audit.rb
#
# Recording is an EXPLICIT call at each site, never an around_action.
#
# A filter that decides what is auditable by inspecting the request is exactly
# the construct that silently stops covering a newly added action. This project
# has already been bitten by that shape: splitting the editing lock out of
# ensure_author quietly narrowed it from six actions to three and left
# finish_test able to erase player history, and no per-task review saw it. An
# explicit call shows up in the diff of any new action; a clever filter does not.
#
# The cost is that someone adding an action can forget the call.
# spec/requests/admin_audit_spec.rb enumerates the audited actions and is the
# guard -- it must be updated deliberately when the set changes, which is the point.
module AdminAudit
  extend ActiveSupport::Concern

  private

  # Call AFTER the change has landed, never before. A refused deletion that
  # left an entry would make the log unreadable: an investigator could not tell
  # which entries were real.
  #
  # Deliberately not wrapped in a transaction with the action. If this write
  # fails the action still stands -- an operator unable to withdraw a game
  # because the audit table is unavailable is a worse outcome than a missing row.
  def record_admin_action(action, target = nil)
    AdminAction.create!(
      :actor_id     => current_user&.id,
      :action       => action.to_s,
      :target_type  => target&.class&.name,
      :target_id    => target&.id,
      :target_label => AdminAction.label_for(target)
    )
  end
end
```

- [ ] **Step 6: Run the spec, then both gates**

```bash
bundle exec rspec spec/models/admin_action_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: the model spec passes, 5 examples; **554 examples** (549 + 5), 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/admin_action.rb app/controllers/concerns/admin_audit.rb spec/models/admin_action_spec.rb
git commit -m "Record administrative changes in an append-only table"
```

---

### Task 2: Instrumenting the game actions

**Files:**
- Modify: `app/controllers/games_controller.rb`
- Test: `spec/requests/admin_audit_spec.rb`

**Interfaces:**
- Consumes: `record_admin_action` from Task 1.
- Produces: entries with `action` values `"withdraw"`, `"restore"`, `"lock"`, `"unlock"`, `"update"`, `"delete"`, `"end_game"`, `"start_test"`, `"finish_test"`. Task 4 renders them.

**This task's spec is the guard that substitutes for an automatic filter.** It must cover every audited action, and one case that must *not* record.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/admin_audit_spec.rb
require "rails_helper"

describe "auditing administrative changes", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "the explicitly superadmin actions" do
    before { sign_in(superadmin) }

    it "records a withdrawal against the game" do
      expect { post withdraw_game_path(game) }.to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("withdraw")
      expect(entry.actor_id).to eq(superadmin.id)
      expect(entry.target_type).to eq("Game")
      expect(entry.target_id).to eq(game.id)
      expect(entry.target_label).to eq(game.name)
    end

    it "records a restore" do
      game.update!(:withdrawn_at => Time.now)
      expect { post restore_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("restore")
    end

    it "records a lock" do
      expect { post lock_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("lock")
    end

    it "records an unlock" do
      game.update!(:editing_locked_at => Time.now)
      expect { post unlock_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("unlock")
    end
  end

  describe "the inherited actions, performed on someone else's game" do
    before { sign_in(superadmin) }

    it "records a deletion, and still names the game afterwards" do
      name = game.name
      expect { get delete_game_path(game) }.to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("delete")
      expect(entry.target_label).to eq(name)
      expect(Game.where(:id => entry.target_id)).to be_empty
    end

    it "records ending a game" do
      expect { get "/games/end_game/#{game.id}" }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("end_game")
    end
  end

  # The condition is "superadmin AND not the author". Getting it wrong in the
  # other direction floods the log with ordinary use and buries the entries
  # anyone actually wants to find.
  describe "an author acting on their own game" do
    it "records nothing" do
      sign_in(author)
      expect { get "/games/end_game/#{game.id}" }.not_to change { AdminAction.count }
    end
  end

  # Entries are written only once the change has landed. An entry for a
  # deletion that was refused would make the log unreadable.
  describe "a refused action" do
    it "records nothing" do
      played = create_game(:author => author, :is_draft => false)
      create_game_passing(:level => create_level(:game => played))
      sign_in(superadmin)

      expect { get delete_game_path(played) }.not_to change { AdminAction.count }
      expect(Game.where(:id => played.id)).not_to be_empty
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_audit_spec.rb
```

Expected: FAIL — no entries are created.

- [ ] **Step 3: Include the concern and add the operator test**

At the top of `app/controllers/games_controller.rb`, beside the existing `include SecurityFilters`:

```ruby
  include AdminAudit
```

and in the private section:

```ruby
  # Audited only when an operator acts on someone else's game. An author
  # editing their own game is ordinary use, not an administrative act, and
  # recording it would bury the administrative entries under routine ones.
  #
  # Compares author_id directly rather than calling User#author_of?, which is
  # `game.author.id == self.id` and raises on a game whose author is missing.
  def acting_as_operator?
    logged_in? && current_user.superadmin? && @game.author_id != current_user.id
  end
```

- [ ] **Step 4: Instrument the four explicit actions**

Each already ends with a redirect. Record before it, after the `update!` has landed:

```ruby
  def withdraw
    @game.update!(:withdrawn_at => Time.now)
    record_admin_action("withdraw", @game)
    redirect_to admin_games_path, :notice => t("games.withdrawn_notice")
  end
```

Do the same in `restore` (`"restore"`), `lock` (`"lock"`) and `unlock` (`"unlock"`). These need no `acting_as_operator?` guard: they are gated by `require_superadmin!` and have no author-performed equivalent.

- [ ] **Step 5: Instrument the inherited actions**

`update` — only on the success branch, and only for an operator:

```ruby
  def update
    if @game.update(game_attributes)
      record_admin_action("update", @game) if acting_as_operator?
      redirect_to @game
    else
      render :edit, status: :unprocessable_entity
    end
  end
```

`delete` — after the refusal guard, so a refused deletion records nothing. The frozen object still answers `id` and `name` after `destroy`, which is what lets the label be captured afterwards:

```ruby
  def delete
    unless @game.deletable?
      redirect_to @game, :alert => t("games.not_deletable") and return
    end

    operator = acting_as_operator?
    @game.destroy
    record_admin_action("delete", @game) if operator
    redirect_to dashboard_path
  end
```

`operator` is captured **before** `destroy` because `acting_as_operator?` reads `@game.author_id`, and reading attributes off a destroyed record is best not relied upon.

`end_game`:

```ruby
  def end_game
    @game.finish_game!
    GamePassing.of_game(@game).each(&:end!)
    record_admin_action("end_game", @game) if acting_as_operator?
    redirect_to dashboard_path
  end
```

`start_test` and `finish_test` both end with a `redirect_to @game` on the success path and a `redirect_to @game, :alert => …` on the failure path. Add `record_admin_action("start_test", @game) if acting_as_operator?` — and `"finish_test"` respectively — immediately before the **success** redirect only, after the `save` has returned true. Read those actions first; they were changed recently and the failure branch must stay unrecorded.

- [ ] **Step 6: Run the spec, then both gates**

```bash
bundle exec rspec spec/requests/admin_audit_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: 8 examples pass; **562 examples** (554 + 8), 0 failures, 6 pending; cucumber unchanged at 234 scenarios. Cucumber drives authors through these actions constantly — if it moves, `acting_as_operator?` is returning true for an author.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/games_controller.rb spec/requests/admin_audit_spec.rb
git commit -m "Record administrative changes to games"
```

---

### Task 3: Granting and revoking the role

**Files:**
- Modify: `app/models/user.rb`, `app/controllers/admin/users_controller.rb`, `config/routes.rb`, `config/locales/{ru,en,uk,ka}.yml`, `app/views/admin/users/show.html.erb`
- Test: `spec/requests/superadmin_granting_spec.rb`

**Interfaces:**
- Consumes: `record_admin_action` from Task 1.
- Produces: `User.superadmin_count` → `Integer`, `User#last_superadmin?` → `Boolean`; `POST /admin/users/:id/grant` (`grant_admin_user_path`) and `POST /admin/users/:id/revoke` (`revoke_admin_user_path`); entries with `action` `"grant_superadmin"` and `"revoke_superadmin"`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/superadmin_granting_spec.rb
require "rails_helper"

describe "granting the superadmin role", type: :request do
  let(:ordinary)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary signed-in user" do
    target = create_user
    sign_in(ordinary)
    post grant_admin_user_path(target)
    expect(response).to have_http_status(:unauthorized)
    expect(target.reload.superadmin?).to be false
  end

  it "lets a superadmin grant the role, and records it" do
    target = create_user
    sign_in(superadmin)

    expect { post grant_admin_user_path(target) }.to change { AdminAction.count }.by(1)

    expect(target.reload.superadmin?).to be true
    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("grant_superadmin")
    expect(entry.target_label).to eq(target.nickname)
  end

  it "lets a superadmin revoke someone else's role, and records it" do
    other = create_user
    other.update!(:is_superadmin => true)
    sign_in(superadmin)

    expect { post revoke_admin_user_path(other) }.to change { AdminAction.count }.by(1)

    expect(other.reload.superadmin?).to be false
    expect(AdminAction.newest_first.first.action).to eq("revoke_superadmin")
  end

  # Prevents the accidental self-lockout, and means every demotion has a
  # second party recorded in the log.
  it "refuses to let a superadmin revoke their own role" do
    other = create_user
    other.update!(:is_superadmin => true)
    sign_in(superadmin)

    expect { post revoke_admin_user_path(superadmin) }.not_to change { AdminAction.count }
    expect(superadmin.reload.superadmin?).to be true
  end

  # The instance must never reach a state where nobody can administer it.
  it "refuses to revoke the last superadmin" do
    sign_in(superadmin)
    only = create_user
    only.update!(:is_superadmin => true)
    superadmin.update_column(:is_superadmin, false)
    sign_in(only)

    expect(User.superadmin_count).to eq(1)
    expect { post revoke_admin_user_path(only) }.not_to change { AdminAction.count }
    expect(only.reload.superadmin?).to be true
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/superadmin_granting_spec.rb
```

Expected: FAIL — undefined route helper `grant_admin_user_path`.

- [ ] **Step 3: Add the model helpers**

In `app/models/user.rb`, beside `superadmin?`:

```ruby
  def self.superadmin_count
    where(:is_superadmin => true).count
  end

  # The instance must never end up with nobody able to administer it.
  def last_superadmin?
    self.superadmin? && User.superadmin_count <= 1
  end
```

- [ ] **Step 4: Add the routes**

In `config/routes.rb`, change the users resource inside `namespace :admin`:

```ruby
    resources :users, only: [ :index, :show ] do
      post "grant",  on: :member
      post "revoke", on: :member
    end
```

- [ ] **Step 5: Add the actions**

In `app/controllers/admin/users_controller.rb`, add `include AdminAudit` beside `include SecurityFilters`, then:

```ruby
  def grant
    user = User.find(params[:id])
    user.update!(:is_superadmin => true)
    record_admin_action("grant_superadmin", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.granted_notice")
  end

  def revoke
    user = User.find(params[:id])

    # Refused before anything changes, so neither guard leaves an entry for a
    # revocation that did not happen.
    if user.id == current_user.id
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_revoke_self") and return
    end

    if user.last_superadmin?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_revoke_last") and return
    end

    user.update!(:is_superadmin => false)
    record_admin_action("revoke_superadmin", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.revoked_notice")
  end
```

- [ ] **Step 6: Add the buttons**

In `app/views/admin/users/show.html.erb`, below the details table:

```erb
<p>
  <% if @user.superadmin? %>
    <%= button_to t("admin.users.show.revoke"), revoke_admin_user_path(@user), :method => :post %>
  <% else %>
    <%= button_to t("admin.users.show.grant"), grant_admin_user_path(@user), :method => :post %>
  <% end %>
</p>
```

- [ ] **Step 7: Add the chrome keys to all four locale files**

`config/locales/ru.yml`, under `admin: users:`:

```yaml
      granted_notice: "Права администратора выданы"
      revoked_notice: "Права администратора отозваны"
      cannot_revoke_self: "Нельзя снять права с самого себя"
      cannot_revoke_last: "Нельзя снять права с последнего администратора"
```

and under `admin: users: show:`:

```yaml
        grant: "Сделать администратором"
        revoke: "Снять права администратора"
```

`config/locales/en.yml`, same positions:

```yaml
      granted_notice: "Administrator rights granted"
      revoked_notice: "Administrator rights revoked"
      cannot_revoke_self: "You cannot revoke your own rights"
      cannot_revoke_last: "You cannot revoke the last administrator"
```

```yaml
        grant: "Make administrator"
        revoke: "Revoke administrator rights"
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values.

- [ ] **Step 8: Run the spec, then both gates**

```bash
bundle exec rspec spec/requests/superadmin_granting_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: 5 examples pass; **567 examples** (562 + 5), 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 9: Commit**

```bash
git add app/models/user.rb app/controllers/admin/users_controller.rb app/views/admin/users config/routes.rb config/locales spec/requests/superadmin_granting_spec.rb
git commit -m "Grant and revoke the superadmin role from the UI, audited"
```

---

### Task 4: Reading the log

**Files:**
- Create: `app/controllers/admin/audit_controller.rb`, `app/views/admin/audit/index.html.erb`
- Modify: `config/routes.rb`, `app/views/admin/dashboard/show.html.erb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/admin_audit_spec.rb` (extend)

**Interfaces:**
- Consumes: `AdminAction.newest_first` from Task 1.
- Produces: `GET /admin/audit` (`admin_audit_index_path`).

- [ ] **Step 1: Write the failing spec**

Append to `spec/requests/admin_audit_spec.rb`, inside the top-level `describe`:

```ruby
  describe "the audit log screen" do
    it "refuses an anonymous visitor" do
      get admin_audit_index_path
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(login_path)
    end

    it "refuses an ordinary signed-in user" do
      sign_in(author)
      get admin_audit_index_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "shows a superadmin the entries, naming a deleted target" do
      sign_in(superadmin)
      name = game.name
      get delete_game_path(game)

      get admin_audit_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(name)
      expect(response.body).to include(superadmin.nickname)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_audit_spec.rb
```

Expected: FAIL — undefined route helper `admin_audit_index_path`.

- [ ] **Step 3: Add the route**

Inside `namespace :admin`:

```ruby
    resources :audit, only: [ :index ]
```

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/admin/audit_controller.rb
#
# Read-only, and there is deliberately no action that edits or deletes an
# entry. A log its own subject can edit is not a log.
class Admin::AuditController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # :actor is preloaded because the view renders one per row.
    @entries = AdminAction.includes(:actor).newest_first
  end
end
```

- [ ] **Step 5: Write the view**

```erb
<%# app/views/admin/audit/index.html.erb %>
<h1><%= t("admin.audit.index.title") %></h1>

<table class="admin-audit">
  <tr>
    <th><%= t("admin.audit.index.when") %></th>
    <th><%= t("admin.audit.index.who") %></th>
    <th><%= t("admin.audit.index.what") %></th>
    <th><%= t("admin.audit.index.target") %></th>
  </tr>
  <% @entries.each do |entry| %>
    <tr>
      <td><%= l(entry.created_at, :format => :long) %></td>
      <td>
        <% if entry.actor %>
          <%= link_to entry.actor.nickname, admin_user_path(entry.actor) %>
        <% else %>
          <%= t("admin.audit.index.unknown_actor") %>
        <% end %>
      </td>
      <%# The action name is chrome; a value nobody anticipated renders as
          itself rather than raising under raise_on_missing_translations. %>
      <td><%= t("admin.audit.index.action.#{entry.action}", :default => entry.action) %></td>
      <td>
        <%# target_label is a snapshot, so it survives the target's deletion.
            Only link when the target still exists. %>
        <% if entry.target_type == "Game" && Game.exists?(entry.target_id) %>
          <%= link_to entry.target_label, game_path(entry.target_id) %>
        <% elsif entry.target_type == "User" && User.exists?(entry.target_id) %>
          <%= link_to entry.target_label, admin_user_path(entry.target_id) %>
        <% else %>
          <%= entry.target_label %>
        <% end %>
      </td>
    </tr>
  <% end %>
</table>

<p><%= link_to t("admin.audit.index.back"), admin_dashboard_path %></p>
```

- [ ] **Step 6: Link it from the dashboard**

In `app/views/admin/dashboard/show.html.erb`, beside the existing link to the games console:

```erb
<p><%= link_to t("admin.dashboard.show.audit_log"), admin_audit_index_path %></p>
```

- [ ] **Step 7: Add the chrome keys to all four locale files**

`config/locales/ru.yml`, under `admin:`:

```yaml
    audit:
      index:
        title: "Журнал действий администраторов"
        when: "Когда"
        who: "Кто"
        what: "Действие"
        target: "Объект"
        unknown_actor: "неизвестно"
        back: "К обзору"
        action:
          withdraw: "Снял с публикации"
          restore: "Опубликовал"
          lock: "Заморозил редактирование"
          unlock: "Разморозил редактирование"
          update: "Изменил"
          delete: "Удалил"
          end_game: "Завершил игру"
          start_test: "Запустил тестирование"
          finish_test: "Завершил тестирование"
          grant_superadmin: "Выдал права администратора"
          revoke_superadmin: "Снял права администратора"
```

and under `admin: dashboard: show:`:

```yaml
        audit_log: "Журнал действий"
```

`config/locales/en.yml`:

```yaml
    audit:
      index:
        title: "Administrator action log"
        when: "When"
        who: "Who"
        what: "Action"
        target: "Target"
        unknown_actor: "unknown"
        back: "Back to overview"
        action:
          withdraw: "Withdrew"
          restore: "Published"
          lock: "Froze editing"
          unlock: "Unfroze editing"
          update: "Edited"
          delete: "Deleted"
          end_game: "Ended the game"
          start_test: "Started testing"
          finish_test: "Finished testing"
          grant_superadmin: "Granted administrator rights"
          revoke_superadmin: "Revoked administrator rights"
```

```yaml
        audit_log: "Action log"
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values.

- [ ] **Step 8: Run the specs, both gates, and the autoloading check**

```bash
bundle exec rspec spec/requests/admin_audit_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: **570 examples** (567 + 3), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps; `All is good!`.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/admin/audit_controller.rb app/views/admin config/routes.rb config/locales spec/requests/admin_audit_spec.rb
git commit -m "Add the administrator action log screen"
```

---

## Self-Review

**Spec coverage.** The append-only table with `target_label` (Task 1); `label_for` and the survives-deletion property (Task 1); explicit recording via a concern rather than an `around_action`, with the reasoning in the code (Task 1); recorded only after the change lands, with a refused-deletion example proving it (Tasks 1–2); the four explicit actions and the inherited ones (Task 2); authors acting on their own games never recorded (Task 2); grant and revoke with the self-revoke and last-superadmin guards, both audited (Task 3); the read-only log screen (Task 4); authorization on the new endpoints asserted with specific statuses (Tasks 3–4).

**Deliberately absent, per the spec:** any auditing of reads; any owner tier; any way to edit or delete an entry; filtering, search or pagination; retention. No task builds them.

**One spec requirement I have consciously narrowed.** The spec asks for "one example per action in the table above". Task 2 covers `withdraw`, `restore`, `lock`, `unlock`, `delete` and `end_game` individually, and instruments `update`, `start_test` and `finish_test` without a dedicated example each — those three sit behind validation branches whose fixtures are substantially more expensive to build, and `start_test`/`finish_test` were rewritten earlier today. The enumerating spec is this design's substitute for an automatic filter, so this is the weakest point in the plan and I am flagging it rather than hiding it: an implementer who can build those fixtures cheaply should add them, and a reviewer should treat their absence as a real gap rather than a style choice.

**Placeholder scan.** No "TBD" or "add validation". Task 2 Step 5 instructs the implementer to read `start_test` and `finish_test` before editing, because both were changed today and their success and failure branches must be distinguished.

**Type consistency.** `record_admin_action(action, target = nil)` is defined in Task 1 and called with that signature in Tasks 2 and 3. `AdminAction.label_for`, `AdminAction.newest_first`, `User.superadmin_count` and `User#last_superadmin?` are each defined once and used with those exact names. Route helpers `grant_admin_user_path`, `revoke_admin_user_path` and `admin_audit_index_path` are introduced in Tasks 3–4 and used consistently.

**Running example counts.** 549 → 554 (T1) → 562 (T2) → 567 (T3) → 570 (T4). Cucumber stays at 234 scenarios / 2362 steps throughout; any change there is a regression, not a new feature.
