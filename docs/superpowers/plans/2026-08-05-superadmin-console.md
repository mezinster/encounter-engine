# Superadmin Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the instance operator a role that can see every game, edit any of them, freeze an author's editing, withdraw a game from players, and delete one only when nobody has played it.

**Architecture:** One boolean column and a `User#superadmin?` predicate, following this codebase's existing capability-predicate style. Enforcement rides the single `ensure_author` filter that six controllers already share, so the role inherits authorship powers everywhere they exist rather than growing a parallel permission system. Two nullable timestamps on `games` hook into the places that already decide visibility. One new read-only controller lists everything.

**Tech Stack:** Ruby 3.3.12, Rails 8.0.5.1, SQLite (dev/test), PostgreSQL (production), RSpec 3.13.

## Global Constraints

- Ruby is pinned to `3.3.12` and Rails to `8.0.5.1`. Do not change either.
- rbenv is not on PATH in non-login shells. Prefix every Ruby command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never create, edit or delete any file under `features/`.** Those `.feature` files are the contract the Merb→Rails port was validated against, whitespace included. If one appears to contradict this plan, stop and report it.
- Existing gates must stay green: `bundle exec rspec` is **481 examples, 0 failures, 6 pending**; `bundle exec cucumber` is **234 scenarios (2 pre-existing "undefined" placeholders), 2362 steps**.
- **Platform chrome goes through `t()`; author-written game content is rendered verbatim.** Every string this plan adds to a view is chrome.
- Translation keys must be added to **all four** of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb` enforces leaf-key and interpolation parity and will fail the build otherwise. `uk` and `ka` reuse the Russian string.
- `config/environments/test.rb` sets `raise_on_missing_translations`, so a missing key fails loudly rather than rendering a placeholder.
- Object factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` (`create_user`, `create_game`, `create_level`, `create_hint`, `create_question`, `create_game_passing`, `create_team`). Do not introduce FactoryBot.
- New specs use `expect`, not the legacy `should` syntax.
- Hash rockets (`:key => value`) are the surrounding style in the older models, controllers and views. Match the file you are editing.
- Migrations use standard Rails 8 class naming. Only the ported Merb-era migrations carry a `_migration` suffix; do not imitate them.
- **Out of scope, per the spec:** the audit trail, the role-granting UI (sub-project B), and any control acting on a running game's `GamePassing` records (sub-project C). Do not build them.

### Facts verified against the running app while writing this plan

Do not re-derive these; do check anything this plan does *not* state.

- `ensure_author` lives in `app/controllers/concerns/security_filters.rb` and reads exactly:
  `raise Authentication::Unauthorized, t("errors.must_be_author") unless logged_in? && current_user.author_of?(@game)`. The key is `errors.must_be_author`.
- The visibility choke points are: the `Game.non_drafts` scope (`app/models/game.rb:34`), `Game.started` and `Game.notstarted` (class methods, `app/models/game.rb:37` and `:65`), and the draft guard in `app/views/games/show.html.erb:5`. `GamesController#index` uses `Game.non_drafts`; `app/views/shared/_current_games.html.erb` uses `Game.started`.
- The delete action is `GamesController#delete` (not `#destroy`) and calls `@game.destroy`.
- **`db/schema.rb` declares zero foreign keys, and `Game`'s `has_many` associations carry no `dependent:` option.** `@game.destroy` therefore orphans every level, log, game entry and game passing — proven with a probe: the game row disappears and the level remains with a dangling `game_id`.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/<ts>_add_is_superadmin_to_users.rb` | The role column |
| `db/migrate/<ts>_add_locks_to_games.rb` | `editing_locked_at`, `withdrawn_at` |
| `app/controllers/admin/games_controller.rb` | The all-games listing |
| `app/views/admin/games/index.html.erb` | The console itself |
| `spec/models/user/superadmin_spec.rb` | The predicate |
| `spec/models/game/locks_spec.rb` | Lock predicates and scopes |
| `spec/requests/superadmin_authorization_spec.rb` | Who may do what |
| `spec/requests/admin_console_spec.rb` | The console's own behaviour |

**Modified:**

| File | Change |
|---|---|
| `app/models/user.rb` | `superadmin?` |
| `app/models/game.rb` | Lock predicates, `dependent:` options, `deletable?`, scope changes |
| `app/controllers/concerns/security_filters.rb` | Widen `ensure_author`; add `require_superadmin!` |
| `app/controllers/games_controller.rb` | Withdraw/lock actions; refuse unsafe delete |
| `config/routes.rb` | The admin namespace and the new member routes |
| `config/locales/{ru,en,uk,ka}.yml` | New chrome keys |

---

### Task 1: The role and the widened filter

**Files:**
- Create: `db/migrate/<ts>_add_is_superadmin_to_users.rb`, `spec/models/user/superadmin_spec.rb`, `spec/requests/superadmin_authorization_spec.rb`
- Modify: `app/models/user.rb`, `app/controllers/concerns/security_filters.rb`

**Interfaces:**
- Produces: `User#superadmin?` → Boolean; `require_superadmin!` (private controller method raising `Authentication::Unauthorized`). Task 5 uses `require_superadmin!`; Tasks 2–4 rely on `ensure_author` admitting superadmins.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/models/user/superadmin_spec.rb
require "rails_helper"

describe User do
  it "is not a superadmin by default" do
    expect(create_user.superadmin?).to be false
  end

  it "is a superadmin when the flag is set" do
    user = create_user
    user.update!(:is_superadmin => true)
    expect(user.reload.superadmin?).to be true
  end
end
```

```ruby
# spec/requests/superadmin_authorization_spec.rb
require "rails_helper"

describe "superadmin authorization", type: :request do
  let(:author)     { create_user }
  let(:stranger)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "password" }
  end

  it "lets the author edit their own game" do
    sign_in(author)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end

  # The bug class this codebase has actually shipped: a destructive action
  # reachable by someone who is neither the author nor an operator.
  it "refuses a stranger" do
    sign_in(stranger)
    get edit_game_path(game)
    expect(response).not_to have_http_status(:ok)
  end

  it "lets a superadmin edit someone else's game" do
    sign_in(superadmin)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end

  it "still refuses an anonymous visitor" do
    get edit_game_path(game)
    expect(response).not_to have_http_status(:ok)
  end
end
```

The sign-in helper was verified against the running app: `config/routes.rb` maps `GET /login` to `sessions#new` (the form) and `PUT /login` to `sessions#update` (the login itself), and `SessionsController` reads `params[:email]` and `params[:password]`. Note the fixture helper `create_user` must produce a user whose password is what this helper sends — read `spec/spec_helpers/fixtures_helper.rb` and use the password it actually sets.

- [ ] **Step 2: Run them to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/user/superadmin_spec.rb spec/requests/superadmin_authorization_spec.rb
```

Expected: FAIL — `undefined method 'superadmin?'`, and the superadmin example failing on authorization.

- [ ] **Step 3: Write the migration**

```bash
bin/rails generate migration AddIsSuperadminToUsers
```

```ruby
class AddIsSuperadminToUsers < ActiveRecord::Migration[8.0]
  def change
    # Defaulted and non-null, so every existing row is valid without a backfill
    # and nobody gains the role by accident.
    add_column :users, :is_superadmin, :boolean, default: false, null: false
  end
end
```

```bash
bin/rails db:migrate && bin/rails db:test:prepare
```

- [ ] **Step 4: Add the predicate**

In `app/models/user.rb`, beside the existing `captain?` and `author_of?`:

```ruby
  def superadmin?
    self.is_superadmin
  end
```

- [ ] **Step 5: Widen the filter and add the superadmin gate**

In `app/controllers/concerns/security_filters.rb`:

```ruby
  # SECURITY CHOKEPOINT. Widening this admits superadmins to every action that
  # gates on it -- levels, hints, questions, game entries -- which is the point:
  # an operator who can edit a game can already edit its levels, and a parallel
  # permission system would drift out of sync with this one. The consequence is
  # that any FUTURE call site of ensure_author silently admits superadmins too.
  def ensure_author
    return if logged_in? && current_user.superadmin?

    raise Authentication::Unauthorized, t("errors.must_be_author") unless logged_in? && current_user.author_of?(@game)
  end

  def require_superadmin!
    raise Authentication::Unauthorized, t("errors.must_be_superadmin") unless logged_in? && current_user.superadmin?
  end
```

- [ ] **Step 6: Add the chrome key to all four locale files**

`config/locales/ru.yml`, under `errors:`:

```yaml
    must_be_superadmin: "Доступ только для администратора"
```

`config/locales/en.yml`:

```yaml
    must_be_superadmin: "Administrator access only"
```

Same key in `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 7: Run the specs, then both full gates**

```bash
bundle exec rspec spec/models/user/superadmin_spec.rb spec/requests/superadmin_authorization_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: the new specs pass; **487 examples** (481 + 6), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps. Cucumber exercises `ensure_author` heavily as an author — a regression means the early return is wrong.

- [ ] **Step 8: Commit**

```bash
git add db/migrate db/schema.rb app/models/user.rb app/controllers/concerns/security_filters.rb config/locales spec/models/user spec/requests/superadmin_authorization_spec.rb
git commit -m "Add a superadmin role, enforced through the existing ensure_author filter"
```

---

### Task 2: The editing lock

**Files:**
- Create: `db/migrate/<ts>_add_locks_to_games.rb`, `spec/models/game/locks_spec.rb`
- Modify: `app/models/game.rb`, `app/controllers/concerns/security_filters.rb`

**Interfaces:**
- Consumes: `User#superadmin?` from Task 1.
- Produces: `Game#editing_locked?` → Boolean, `Game#withdrawn?` → Boolean, and the `editing_locked_at` / `withdrawn_at` columns. Task 3 uses `withdrawn?`; Task 5 displays both.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/game/locks_spec.rb
require "rails_helper"

describe Game do
  it "is neither locked nor withdrawn by default" do
    game = create_game
    expect(game.editing_locked?).to be false
    expect(game.withdrawn?).to be false
  end

  it "reports an editing lock once the timestamp is set" do
    game = create_game
    game.update!(:editing_locked_at => Time.now)
    expect(game.reload.editing_locked?).to be true
  end

  it "reports withdrawal once the timestamp is set" do
    game = create_game
    game.update!(:withdrawn_at => Time.now)
    expect(game.reload.withdrawn?).to be true
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/locks_spec.rb
```

Expected: FAIL — `undefined method 'editing_locked?'`.

- [ ] **Step 3: Write the migration**

```bash
bin/rails generate migration AddLocksToGames
```

```ruby
class AddLocksToGames < ActiveRecord::Migration[8.0]
  def change
    # Timestamps rather than booleans: the console shows WHEN, which is what an
    # operator wants while investigating. Nullable, so no existing row changes.
    add_column :games, :editing_locked_at, :datetime
    add_column :games, :withdrawn_at,      :datetime
  end
end
```

```bash
bin/rails db:migrate && bin/rails db:test:prepare
```

- [ ] **Step 4: Add the predicates**

In `app/models/game.rb`, beside `draft?` and `started?`:

```ruby
  def editing_locked?
    self.editing_locked_at.present?
  end

  def withdrawn?
    self.withdrawn_at.present?
  end
```

- [ ] **Step 5: Enforce the editing lock**

In `app/controllers/concerns/security_filters.rb`, extend `ensure_author`:

```ruby
  def ensure_author
    return if logged_in? && current_user.superadmin?

    raise Authentication::Unauthorized, t("errors.must_be_author") unless logged_in? && current_user.author_of?(@game)
    raise Authentication::Unauthorized, t("errors.game_is_locked") if @game&.editing_locked?
  end
```

Order matters: the superadmin returns before the lock check, so a lock never freezes the operator who applied it. The lock covers content and settings only — lifecycle actions remain available to a superadmin, because they pass this same filter.

- [ ] **Step 6: Add a spec for the lock's effect on each party**

Append to `spec/requests/superadmin_authorization_spec.rb`:

```ruby
  it "stops the author editing a locked game" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(author)
    get edit_game_path(game)
    expect(response).not_to have_http_status(:ok)
  end

  it "still lets a superadmin edit a locked game" do
    game.update!(:editing_locked_at => Time.now)
    sign_in(superadmin)
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
  end
```

- [ ] **Step 7: Add the chrome key to all four locale files**

`config/locales/ru.yml`, under `errors:`:

```yaml
    game_is_locked: "Редактирование игры заморожено администратором"
```

`config/locales/en.yml`:

```yaml
    game_is_locked: "Editing this game has been frozen by an administrator"
```

Same key in `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 8: Run the specs, then both full gates**

```bash
bundle exec rspec spec/models/game/locks_spec.rb spec/requests/superadmin_authorization_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **492 examples** (487 + 5), 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb app/models/game.rb app/controllers/concerns/security_filters.rb config/locales spec/models/game/locks_spec.rb spec/requests/superadmin_authorization_spec.rb
git commit -m "Add an editing lock that freezes the author but not the operator"
```

---

### Task 3: Withdrawal, at every choke point

**Files:**
- Modify: `app/models/game.rb`, `app/controllers/games_controller.rb`, `config/routes.rb`
- Test: `spec/requests/withdrawal_spec.rb`

**Interfaces:**
- Consumes: `Game#withdrawn?` from Task 2, `require_superadmin!` from Task 1.
- Produces: `POST /games/:id/withdraw` (`withdraw_game_path`) and `POST /games/:id/restore` (`restore_game_path`); `Game.visible` scope. Task 5 links to both.

**Why this task is its own gate:** a withdrawn game that is still reachable through any one of the four choke points is not withdrawn. Each gets its own example.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/withdrawal_spec.rb
require "rails_helper"

describe "withdrawal", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => false) }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "password" }
  end

  it "removes the game from the public listing" do
    game.update!(:withdrawn_at => Time.now)
    expect(Game.visible).not_to include(game)
    expect(Game.non_drafts).to include(game)  # the raw scope is unchanged
  end

  it "keeps it out of the started and notstarted selectors" do
    game.update!(:withdrawn_at => Time.now, :starts_at => Time.now - 1.hour)
    expect(Game.started).not_to include(game)
    expect(Game.notstarted).not_to include(game)
  end

  # The operator's own view must keep working, or every withdrawal generates a
  # support question from the author asking where their game went.
  it "stays visible to its author and to a superadmin" do
    game.update!(:withdrawn_at => Time.now)
    sign_in(author)
    get game_path(game)
    expect(response).to have_http_status(:ok)
  end

  it "can be withdrawn and restored by a superadmin" do
    sign_in(superadmin)
    post withdraw_game_path(game)
    expect(game.reload.withdrawn?).to be true
    post restore_game_path(game)
    expect(game.reload.withdrawn?).to be false
  end

  it "cannot be withdrawn by the author" do
    sign_in(author)
    post withdraw_game_path(game)
    expect(game.reload.withdrawn?).to be false
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/withdrawal_spec.rb
```

Expected: FAIL — `undefined method 'visible'` and undefined route helpers.

- [ ] **Step 3: Add the scope and filter the selectors**

In `app/models/game.rb`:

```ruby
  # The single place "may a player see this?" is answered. non_drafts stays as
  # it is -- other callers use it for its literal meaning -- and this composes
  # on top, so a future caller that forgets `visible` is a visible mistake
  # rather than a silent leak.
  scope :visible, -> { non_drafts.where(:withdrawn_at => nil) }
```

and change the two class methods to build on it:

```ruby
  def self.started
    Game.visible.select(&:started?)
  end

  def self.notstarted
    Game.visible.reject(&:started?)
  end
```

Read the existing bodies of `self.started` and `self.notstarted` first and preserve whatever else they do — this step changes what they select *from*, not their logic.

- [ ] **Step 4: Point the public listing at the scope**

In `app/controllers/games_controller.rb`, the `index` action currently uses `Game.non_drafts`. Change that one reference to `Game.visible`. Leave any author-scoped listing (`Game.by(current_user)`) alone — an author must keep seeing their own withdrawn game.

- [ ] **Step 5: Add the actions and routes**

In `app/controllers/games_controller.rb`:

```ruby
  def withdraw
    @game.update!(:withdrawn_at => Time.now)
    redirect_to admin_games_path, :notice => t("games.withdrawn_notice")
  end

  def restore
    @game.update!(:withdrawn_at => nil)
    redirect_to admin_games_path, :notice => t("games.restored_notice")
  end
```

Add `:withdraw, :restore` to whichever `before_action` loads `@game`, and gate them with `before_action :require_superadmin!, only: [:withdraw, :restore]`.

In `config/routes.rb`, inside the existing `resources :games` block:

```ruby
    post "withdraw", on: :member
    post "restore",  on: :member
```

- [ ] **Step 6: Add the chrome keys to all four locale files**

`config/locales/ru.yml`, under `games:`:

```yaml
    withdrawn_notice: "Игра снята с публикации"
    restored_notice: "Игра снова опубликована"
```

`config/locales/en.yml`:

```yaml
    withdrawn_notice: "Game withdrawn from players"
    restored_notice: "Game published again"
```

Same keys in `uk.yml` and `ka.yml` with the Russian values.

- [ ] **Step 7: Run the specs, then both full gates**

```bash
bundle exec rspec spec/requests/withdrawal_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **497 examples** (492 + 5), 0 failures, 6 pending; cucumber unchanged at 234 scenarios. Cucumber lists and joins games constantly — a regression means `visible` is filtering something it should not.

- [ ] **Step 8: Commit**

```bash
git add app/models/game.rb app/controllers/games_controller.rb config/routes.rb config/locales spec/requests/withdrawal_spec.rb
git commit -m "Withdraw a game from players without disturbing races in progress"
```

---

### Task 4: Deletion that refuses, and cleans up when it doesn't

**Files:**
- Modify: `app/models/game.rb`, `app/controllers/games_controller.rb`
- Test: `spec/requests/game_deletion_spec.rb`

**Interfaces:**
- Produces: `Game#deletable?` → Boolean (true when no `game_passing` exists). Task 5 uses it to decide whether to offer the control.

**Context you need:** `@game.destroy` currently orphans everything. `db/schema.rb` has zero foreign keys and `Game`'s associations carry no `dependent:` option — verified with a probe in which the game row vanished and its level remained with a dangling `game_id`. So this task both restricts deletion *and* makes the permitted case clean up, which is a change to the existing author-facing delete as well.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/game_deletion_spec.rb
require "rails_helper"

describe "game deletion", type: :request do
  let(:author) { create_user }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "password" }
  end

  it "is allowed when no team has ever played" do
    game = create_game(:author => author, :is_draft => true)
    expect(game.deletable?).to be true
  end

  it "is refused once any team has played" do
    game = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => game))
    expect(game.reload.deletable?).to be false
  end

  # Today's behaviour orphans them: zero foreign keys, no dependent: options.
  it "takes the levels, hints and questions with it" do
    game  = create_game(:author => author, :is_draft => true)
    level = create_level(:game => game)
    hint  = create_hint(:level => level)
    level_id, hint_id = level.id, hint.id

    game.destroy

    expect(Level.where(:id => level_id)).to be_empty
    expect(Hint.where(:id => hint_id)).to be_empty
  end

  it "refuses over HTTP and leaves the game alone" do
    game = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => game))
    sign_in(author)

    delete_game_request(game)

    expect(Game.where(:id => game.id)).not_to be_empty
  end

  # The delete route in this app is GamesController#delete, not #destroy.
  # Confirm its verb and helper in config/routes.rb before running.
  def delete_game_request(game)
    get delete_game_path(game)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_deletion_spec.rb
```

Expected: FAIL — `undefined method 'deletable?'`, and the cascade example failing because the level survives.

- [ ] **Step 3: Make the associations clean up**

In `app/models/game.rb`, add `dependent:` to the associations whose children are the game's own structure. **Do not** add it to `game_passings` or `logs` — deletion is refused whenever those exist, so a cascade there would only ever fire on an empty set, and declaring it would suggest a behaviour we deliberately do not want:

```ruby
  has_many :levels, -> {  order('position') }, :dependent => :destroy
  has_many :game_entries, :class_name => "GameEntry", :dependent => :destroy
```

and in `app/models/level.rb`, so a destroyed level takes its own children:

```ruby
  has_many :questions, :dependent => :destroy
  has_many :answers, :dependent => :destroy
  has_many :hints, -> { order('delay ASC') }, :dependent => :destroy
```

- [ ] **Step 4: Add the predicate and enforce it**

In `app/models/game.rb`:

```ruby
  # Logs and game passings are players' history, not the author's content, and
  # destroy would orphan them rather than remove them -- there are no foreign
  # keys and no dependent: option on those associations. Withdrawal achieves
  # what deletion is usually reached for, without leaving unreachable rows.
  def deletable?
    self.game_passings.empty?
  end
```

In `app/controllers/games_controller.rb`, replace the body of `delete`:

```ruby
  def delete
    unless @game.deletable?
      redirect_to @game, :alert => t("games.not_deletable") and return
    end

    @game.destroy
    redirect_to dashboard_path
  end
```

Read the existing `delete` action first and preserve wherever it currently redirects on success.

- [ ] **Step 5: Add the chrome key to all four locale files**

`config/locales/ru.yml`, under `games:`:

```yaml
    not_deletable: "Игру нельзя удалить: в неё уже играли. Снимите её с публикации."
```

`config/locales/en.yml`:

```yaml
    not_deletable: "This game cannot be deleted because teams have played it. Withdraw it instead."
```

Same key in `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 6: Run the specs, then both full gates**

```bash
bundle exec rspec spec/requests/game_deletion_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **502 examples** (497 + 5), 0 failures, 6 pending; cucumber unchanged. **Watch this one especially:** Cucumber deletes games in several scenarios, and adding `dependent: :destroy` changes what happens underneath. If a scenario regresses, the cascade is reaching something it should not — investigate, do not touch `features/`.

- [ ] **Step 7: Commit**

```bash
git add app/models/game.rb app/models/level.rb app/controllers/games_controller.rb config/locales spec/requests/game_deletion_spec.rb
git commit -m "Refuse to delete a played game, and stop orphaning children when deleting is allowed"
```

---

### Task 5: The console

**Files:**
- Create: `app/controllers/admin/games_controller.rb`, `app/views/admin/games/index.html.erb`, `spec/requests/admin_console_spec.rb`
- Modify: `config/routes.rb`, `config/locales/{ru,en,uk,ka}.yml`

**Interfaces:**
- Consumes: `require_superadmin!` (Task 1), `Game#editing_locked?` / `#withdrawn?` (Task 2), `withdraw_game_path` / `restore_game_path` (Task 3), `Game#deletable?` (Task 4).

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/admin_console_spec.rb
require "rails_helper"

describe "the admin console", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "password" }
  end

  it "refuses an anonymous visitor" do
    get admin_games_path
    expect(response).not_to have_http_status(:ok)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(author)
    get admin_games_path
    expect(response).not_to have_http_status(:ok)
  end

  it "lists every game, including other people's drafts" do
    mine     = create_game(:author => superadmin, :is_draft => false)
    theirs   = create_game(:author => author,     :is_draft => true)
    sign_in(superadmin)

    get admin_games_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(mine.name)
    expect(response.body).to include(theirs.name)
  end

  it "offers withdrawal but not deletion for a game that has been played" do
    played = create_game(:author => author, :is_draft => false)
    create_game_passing(:game => played)
    sign_in(superadmin)

    get admin_games_path

    expect(response.body).to include(withdraw_game_path(played))
    expect(response.body).not_to include(delete_game_path(played))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_console_spec.rb
```

Expected: FAIL — undefined route helper `admin_games_path`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`:

```ruby
  namespace :admin do
    resources :games, only: [ :index ]
  end
```

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/admin/games_controller.rb
#
# Read-only by design. Editing rides the author's own forms -- ensure_author
# admits superadmins -- so there is no second, subtly different game editor to
# keep in sync with the first.
class Admin::GamesController < ApplicationController
  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # "What just appeared on my instance?" is the operator's first question.
    @games = Game.includes(:author).order(:created_at => :desc)
  end
end
```

Check what the authentication filter is actually called in `app/controllers/concerns/authentication.rb` and use the real name.

- [ ] **Step 5: Write the view**

```erb
<%# app/views/admin/games/index.html.erb %>
<h1><%= t("admin.games.index.title") %></h1>

<table class="admin-games">
  <tr>
    <th><%= t("admin.games.index.name") %></th>
    <th><%= t("admin.games.index.author") %></th>
    <th><%= t("admin.games.index.locales") %></th>
    <th><%= t("admin.games.index.status") %></th>
    <th><%= t("admin.games.index.teams") %></th>
    <th></th>
  </tr>
  <% @games.each do |game| %>
    <tr>
      <td><%= link_to game.name, game_path(game) %></td>
      <td><%= game.author&.nickname %></td>
      <td><%= game.available_locale_list.join(", ") %></td>
      <td>
        <% if game.withdrawn? %><%= t("admin.games.index.withdrawn") %>
        <% elsif game.draft? %><%= t("admin.games.index.draft") %>
        <% elsif game.started? %><%= t("admin.games.index.running") %>
        <% else %><%= t("admin.games.index.scheduled") %>
        <% end %>
        <% if game.editing_locked? %> &middot; <%= t("admin.games.index.locked") %><% end %>
      </td>
      <td><%= game.game_passings.size %></td>
      <td>
        <%= link_to t("admin.games.index.edit"), edit_game_path(game) %>
        <% if game.withdrawn? %>
          <%= button_to t("admin.games.index.restore"), restore_game_path(game), :method => :post %>
        <% else %>
          <%= button_to t("admin.games.index.withdraw"), withdraw_game_path(game), :method => :post %>
        <% end %>
        <% if game.deletable? %>
          <%= link_to t("admin.games.index.delete"), delete_game_path(game),
                      :data => { :confirm => t("admin.games.index.delete_confirm", :name => game.name) } %>
        <% end %>
      </td>
    </tr>
  <% end %>
</table>
```

Game names are author-written content and are rendered verbatim; every label around them is chrome through `t()`.

- [ ] **Step 6: Add the chrome keys to all four locale files**

`config/locales/ru.yml`:

```yaml
  admin:
    games:
      index:
        title: "Все игры"
        name: "Название"
        author: "Автор"
        locales: "Языки"
        status: "Статус"
        teams: "Команд"
        draft: "Черновик"
        scheduled: "Запланирована"
        running: "Идёт"
        withdrawn: "Снята с публикации"
        locked: "редактирование заморожено"
        edit: "Редактировать"
        withdraw: "Снять"
        restore: "Опубликовать"
        delete: "Удалить"
        delete_confirm: "Удалить игру «%{name}» со всеми уровнями? Это необратимо."
```

`config/locales/en.yml`:

```yaml
  admin:
    games:
      index:
        title: "All games"
        name: "Name"
        author: "Author"
        locales: "Languages"
        status: "Status"
        teams: "Teams"
        draft: "Draft"
        scheduled: "Scheduled"
        running: "Running"
        withdrawn: "Withdrawn"
        locked: "editing frozen"
        edit: "Edit"
        withdraw: "Withdraw"
        restore: "Publish"
        delete: "Delete"
        delete_confirm: "Delete the game “%{name}” and all its levels? This cannot be undone."
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values. `delete_confirm` interpolates `%{name}` in every locale — `spec/i18n_spec.rb` checks interpolation parity.

- [ ] **Step 7: Run the specs, the full gates, and the autoloading check**

```bash
bundle exec rspec spec/requests/admin_console_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: **506 examples** (502 + 4), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps; `zeitwerk:check` prints `All is good!` — the namespaced controller under `app/controllers/admin/` is exactly the kind of thing that check catches.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/admin app/views/admin config/routes.rb config/locales spec/requests/admin_console_spec.rb
git commit -m "Add the all-games console"
```

---

## Self-Review

**Spec coverage.** The role column and predicate (Task 1); `ensure_author` widened, with its chokepoint comment (Task 1); `require_superadmin!` (Task 1); both lock columns as timestamps (Task 2); the editing lock freezing the author but not the operator, and covering content rather than lifecycle (Task 2); withdrawal at every choke point, with the author's own view preserved (Task 3); withdrawal leaving in-flight play alone — no code touches `GamePassing`, which is how that requirement is met (Task 3); deletion refused once a team has played and cleaning up when permitted (Task 4); the console listing everything with status and both lock states, no search or pagination, no separate editor (Task 5).

**Correction carried from the spec.** The spec originally claimed deletion cascades. It does not — zero foreign keys, no `dependent:` options, proven with a probe. Task 4 therefore both restricts deletion and fixes the orphaning, which is a change to the existing author-facing delete as well. That is deliberate and stated in the task.

**Explicitly out of scope, per the spec:** the audit trail, the granting UI (sub-project B), and any control touching a running game's `GamePassing` records (sub-project C). No task builds them.

**Placeholder scan.** No "TBD" or "add validation". Four steps deliberately tell the implementer to verify a name against the running app rather than trusting this document — the login route and its parameter names (Tasks 1, 3, 4, 5), the existing bodies of `Game.started` / `Game.notstarted` (Task 3), the current `delete` action's redirect (Task 4), and the authentication filter's real name (Task 5). That is a direct response to this project's history: three separate confident claims about this codebase turned out wrong in the previous plan, and every one was checkable in a single command.

**Type consistency.** `superadmin?`, `editing_locked?`, `withdrawn?`, `deletable?` are used with those exact names in every task that references them. `require_superadmin!` is defined in Task 1 and used in Tasks 3 and 5. `Game.visible` is defined in Task 3 and used only there. Route helpers `withdraw_game_path`, `restore_game_path`, `admin_games_path` and `delete_game_path` are used consistently from the tasks that create them onward.

**Running example counts.** 481 → 487 (T1) → 492 (T2) → 497 (T3) → 502 (T4) → 506 (T5). Cucumber stays at 234 scenarios / 2362 steps throughout; any change there is a regression, not a new feature.
