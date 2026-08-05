# Superadmin Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the operator a stats screen showing how many games exist in which states, and a users list they can drill into — without building a query interface and without putting every player's contact details on one page.

**Architecture:** Three read-only controllers under the existing `Admin::` namespace, gated by the `require_superadmin!` filter sub-project A already built. Every figure is a SQL aggregate. Nothing writes; there is no migration.

**Tech Stack:** Ruby 3.3.12, Rails 8.0.5.1, SQLite (dev/test), PostgreSQL (production), RSpec 3.13.

## Global Constraints

- Ruby is pinned to `3.3.12` and Rails to `8.0.5.1`. Do not change either.
- rbenv is not on PATH in non-login shells. Prefix every Ruby command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never create, edit or delete any file under `features/`.** Those `.feature` files are the contract the Merb→Rails port was validated against, whitespace included.
- Existing gates must stay green: `bundle exec rspec` is **522 examples, 0 failures, 6 pending**; `bundle exec cucumber` is **234 scenarios (2 pre-existing "undefined" placeholders), 2362 steps**. `bin/rails zeitwerk:check` must print `All is good!`.
- **`crypted_password` and `salt` are never rendered on any screen.** A displayed hash is an offline cracking target handed to anyone who can screenshot the page.
- **Every count is a SQL aggregate**, never `.select` or `.count` on a loaded collection. `Game.started` loads every row and filters in memory — correct enough for a listing of two, wrong for a counter. Do not build on it.
- **Read-only, without exception.** Every action in this plan is a `GET`. No writes, no role granting, no deletion.
- No pagination and no search. The instance has a handful of users and games.
- **Platform chrome goes through `t()`; author- and user-written content renders verbatim.** Nicknames, emails and game names are content; every label around them is chrome.
- Translation keys go in all four of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb` enforces `ru`↔`en` exact parity and `uk`/`ka` as a subset; `raise_on_missing_translations` is on in test. **On this branch `uk`/`ka` are stubs holding Russian text** — use the Russian value for new keys there and say so in your report. The real translations live on `master` and arrive by merge.
- Factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb`. No FactoryBot. New specs use `expect`.
- Hash rockets (`:key => value`) are the surrounding style in these models and controllers.
- **Out of scope:** any arbitrary-query or SQL-console interface; editing, creating or deleting users; granting or revoking the superadmin role (sub-project B); anything touching a running game's `GamePassing` records (sub-project C); charts, time series and export.

### Facts verified against this app while writing this plan

Do not re-derive these; do check anything this plan does *not* state.

- The established pattern is `app/controllers/admin/games_controller.rb`: `include SecurityFilters`, then `before_action :require_authentication!`, then `before_action :require_superadmin!`. Follow it exactly.
- Routes live in a `namespace :admin do ... end` block at `config/routes.rb:12-14`.
- **`games.is_draft` is `default: false, null: false`** — so `where(:is_draft => false)` is safe and needs no `NULL` handling.
- **`games.starts_at` is nullable.** `Game#started?` treats `NULL` as not started; the SQL must do the same.
- `games.withdrawn_at`, `games.editing_locked_at` and `games.author_finished_at` are all nullable datetimes.
- `GameEntry` has a `status` string column with values `"new"`, `"accepted"`, `"rejected"`, `"recalled"`, `"canceled"`.
- `GamePassing` has `scope :finished, -> { where.not(finished_at: nil) }`.
- `User belongs_to :team, optional: true` and `has_many :created_games, class_name: "Game", foreign_key: "author_id"`. **There is no team history** — `users.team_id` is one column.
- Login is `PUT /login` → `sessions#update`, reading `params[:email]` and `params[:password]`. **`create_user` sets the password `1234`.**
- `spec/support/query_counter.rb` provides `count_queries { … }` and is already required from `spec/rails_helper.rb`.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `app/controllers/admin/dashboard_controller.rb` | The stats screen |
| `app/views/admin/dashboard/show.html.erb` | Counts, rendered |
| `app/controllers/admin/users_controller.rb` | Users list and detail |
| `app/views/admin/users/index.html.erb` | Identity and email per user |
| `app/views/admin/users/show.html.erb` | Contact details, on demand |
| `spec/models/game/count_by_status_spec.rb` | The precedence and the sum |
| `spec/requests/admin_reporting_spec.rb` | Authorization, rendering, the N+1 guard, the hash-absence guard |

**Modified:**

| File | Change |
|---|---|
| `app/models/game.rb` | `Game.count_by_status`, `Game.editing_locked_count` |
| `config/routes.rb` | Two routes inside the existing `namespace :admin` |
| `config/locales/{ru,en,uk,ka}.yml` | New chrome keys |

---

### Task 1: Counting games by status

**Files:**
- Modify: `app/models/game.rb`
- Test: `spec/models/game/count_by_status_spec.rb`

**Interfaces:**
- Produces: `Game.count_by_status(now = Time.now)` → `Hash` with exactly the keys `:withdrawn`, `:draft`, `:finished`, `:running`, `:scheduled`, values `Integer`; and `Game.editing_locked_count` → `Integer`. Task 2 renders both.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/game/count_by_status_spec.rb
require "rails_helper"

describe Game, ".count_by_status" do
  # Every game must land in exactly one bucket. The predicates overlap by
  # construction, so this fixture deliberately includes games that satisfy
  # several of them at once.
  let!(:plain_draft)     { create_game(:is_draft => true) }
  let!(:scheduled)       { create_game(:is_draft => false) }
  let!(:withdrawn_draft) { g = create_game(:is_draft => true);  g.update_column(:withdrawn_at, Time.now); g }
  let!(:finished)        { g = create_game(:is_draft => false); g.update_column(:author_finished_at, Time.now); g }
  let!(:running)         { g = create_game(:is_draft => false); g.update_column(:starts_at, Time.now - 1.hour); g }
  let!(:no_start_time)   { g = create_game(:is_draft => false); g.update_column(:starts_at, nil); g }

  it "puts a withdrawn game in withdrawn, whatever else it is" do
    expect(Game.count_by_status[:withdrawn]).to eq(1)
    expect(Game.count_by_status[:draft]).to eq(1)   # only plain_draft, not withdrawn_draft
  end

  it "counts a finished game as finished rather than running" do
    expect(Game.count_by_status[:finished]).to eq(1)
  end

  it "counts a started, unfinished game as running" do
    expect(Game.count_by_status[:running]).to eq(1)
  end

  # starts_at is nullable and Game#started? treats NULL as not started. A naive
  # `starts_at < now` in SQL evaluates NULL to unknown and silently drops the
  # row from every bucket, which is how a status table stops summing.
  it "counts a game with no start time as scheduled, not as nothing" do
    expect(Game.count_by_status[:scheduled]).to eq(2)  # scheduled + no_start_time
  end

  # The property that catches a mis-specified predicate without anyone having
  # to reason through the precedence.
  it "accounts for every game exactly once" do
    expect(Game.count_by_status.values.sum).to eq(Game.count)
  end

  it "counts locked games separately, since a game can be locked and running" do
    running.update_column(:editing_locked_at, Time.now)
    expect(Game.editing_locked_count).to eq(1)
    expect(Game.count_by_status[:running]).to eq(1)
  end
end
```

`update_column` is used deliberately: it skips validations, which is the only way to put a game into a past-dated or finished state without fighting `game_starts_in_the_future` and the translation-completeness gate.

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/count_by_status_spec.rb
```

Expected: FAIL — `undefined method 'count_by_status'`.

- [ ] **Step 3: Implement both class methods**

Add to `app/models/game.rb`, near the other class methods:

```ruby
  # Each game counts once, under the first status that matches, in this order:
  # withdrawn, draft, finished, running, scheduled. The predicates overlap by
  # construction -- a draft has no start time in the past, a withdrawn game may
  # also be finished -- so without a precedence the columns would not sum to
  # the total and nobody would notice.
  #
  # The order matches how the admin console labels a game in its status column,
  # deliberately: two admin screens disagreeing about what a game IS would be
  # worse than either being wrong on its own.
  #
  # Counted in SQL. Game.started loads every row and filters in memory, which
  # is fine for a listing of two and wrong for a counter.
  def self.count_by_status(now = Time.now)
    live = where(:withdrawn_at => nil)
    published = live.where(:is_draft => false)
    unfinished = published.where(:author_finished_at => nil)

    {
      :withdrawn => where.not(:withdrawn_at => nil).count,
      :draft     => live.where(:is_draft => true).count,
      :finished  => published.where.not(:author_finished_at => nil).count,
      # starts_at is nullable and Game#started? treats NULL as not started, so
      # the NULL check is explicit rather than left to a comparison that would
      # evaluate to unknown and drop the row from every bucket.
      :running   => unfinished.where.not(:starts_at => nil).where("starts_at < ?", now).count,
      :scheduled => unfinished.where("starts_at IS NULL OR starts_at >= ?", now).count
    }
  end

  # Reported alongside the status table rather than as a row in it: a game can
  # be locked AND running, and forcing it into the precedence above would hide
  # one fact in order to show the other.
  def self.editing_locked_count
    where.not(:editing_locked_at => nil).count
  end
```

- [ ] **Step 4: Run the spec**

```bash
bundle exec rspec spec/models/game/count_by_status_spec.rb
```

Expected: PASS, 6 examples.

- [ ] **Step 5: Run both full gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **528 examples** (522 + 6), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps.

- [ ] **Step 6: Commit**

```bash
git add app/models/game.rb spec/models/game/count_by_status_spec.rb
git commit -m "Count games by status in SQL, with an explicit precedence"
```

---

### Task 2: The stats screen

**Files:**
- Create: `app/controllers/admin/dashboard_controller.rb`, `app/views/admin/dashboard/show.html.erb`
- Modify: `config/routes.rb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/admin_reporting_spec.rb`

**Interfaces:**
- Consumes: `Game.count_by_status`, `Game.editing_locked_count` from Task 1.
- Produces: `GET /admin` (`admin_dashboard_path`). Task 3 adds sibling routes in the same namespace.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/admin_reporting_spec.rb
require "rails_helper"

describe "superadmin reporting", type: :request do
  let(:ordinary)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update. create_user sets the password "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "the stats screen" do
    it "refuses an anonymous visitor" do
      get admin_dashboard_path
      expect(response).not_to have_http_status(:ok)
    end

    it "refuses an ordinary signed-in user" do
      sign_in(ordinary)
      get admin_dashboard_path
      expect(response).not_to have_http_status(:ok)
    end

    it "shows a superadmin the counts" do
      create_game(:is_draft => true)
      sign_in(superadmin)

      get admin_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(t_admin("dashboard.show.title"))
    end
  end

  def t_admin(key)
    I18n.t("admin.#{key}")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_reporting_spec.rb
```

Expected: FAIL — undefined route helper `admin_dashboard_path`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the existing `namespace :admin do ... end` block that already contains `resources :games, only: [ :index ]`:

```ruby
    get "/", to: "dashboard#show", as: :dashboard
```

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/admin/dashboard_controller.rb
#
# Read-only. Every figure is a SQL aggregate rather than a count over a loaded
# collection -- an admin page that loads every row to count it becomes the
# slowest page on the site precisely when the instance gets interesting.
class Admin::DashboardController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    @games_by_status = Game.count_by_status
    @editing_locked  = Game.editing_locked_count
    @entries_by_status = GameEntry.group(:status).count

    @counts = {
      :users => User.count,
      :teams => Team.count,
      :games => Game.count,
      :passings_finished => GamePassing.finished.count,
      :passings_in_progress => GamePassing.where(:finished_at => nil).count
    }
  end
end
```

- [ ] **Step 5: Write the view**

```erb
<%# app/views/admin/dashboard/show.html.erb %>
<h1><%= t("admin.dashboard.show.title") %></h1>

<h2><%= t("admin.dashboard.show.games_by_status") %></h2>
<table class="admin-stats">
  <% @games_by_status.each do |status, count| %>
    <tr>
      <th><%= t("admin.dashboard.show.status.#{status}") %></th>
      <td><%= count %></td>
    </tr>
  <% end %>
  <tr>
    <th><%= t("admin.dashboard.show.editing_locked") %></th>
    <td><%= @editing_locked %></td>
  </tr>
</table>

<h2><%= t("admin.dashboard.show.totals") %></h2>
<table class="admin-stats">
  <% @counts.each do |key, count| %>
    <tr>
      <th><%= t("admin.dashboard.show.total.#{key}") %></th>
      <td><%= count %></td>
    </tr>
  <% end %>
</table>

<h2><%= t("admin.dashboard.show.entries_by_status") %></h2>
<table class="admin-stats">
  <% @entries_by_status.each do |status, count| %>
    <tr>
      <%# GameEntry.status is a free string column, so a value nobody
          anticipated must render as itself rather than raise under
          raise_on_missing_translations. %>
      <th><%= t("admin.dashboard.show.entry_status.#{status}", :default => status.to_s) %></th>
      <td><%= count %></td>
    </tr>
  <% end %>
</table>

<p><%= link_to t("admin.dashboard.show.all_games"), admin_games_path %></p>
```

- [ ] **Step 6: Add the chrome keys to all four locale files**

`config/locales/ru.yml`, under the existing `admin:` key:

```yaml
    dashboard:
      show:
        title: "Обзор"
        games_by_status: "Игры по статусу"
        editing_locked: "Редактирование заморожено"
        totals: "Всего"
        entries_by_status: "Заявки по статусу"
        all_games: "Все игры"
        status:
          withdrawn: "Снята с публикации"
          draft: "Черновик"
          finished: "Завершена"
          running: "Идёт"
          scheduled: "Запланирована"
        total:
          users: "Игроков"
          teams: "Команд"
          games: "Игр"
          passings_finished: "Прохождений завершено"
          passings_in_progress: "Прохождений идёт"
        entry_status:
          new: "Новая"
          accepted: "Принята"
          rejected: "Отклонена"
          recalled: "Отозвана"
          canceled: "Отменена"
```

`config/locales/en.yml`:

```yaml
    dashboard:
      show:
        title: "Overview"
        games_by_status: "Games by status"
        editing_locked: "Editing frozen"
        totals: "Totals"
        entries_by_status: "Entry requests by status"
        all_games: "All games"
        status:
          withdrawn: "Withdrawn"
          draft: "Draft"
          finished: "Finished"
          running: "Running"
          scheduled: "Scheduled"
        total:
          users: "Players"
          teams: "Teams"
          games: "Games"
          passings_finished: "Passings finished"
          passings_in_progress: "Passings in progress"
        entry_status:
          new: "New"
          accepted: "Accepted"
          rejected: "Rejected"
          recalled: "Recalled"
          canceled: "Canceled"
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values, matching every other key in those two files on this branch.

- [ ] **Step 7: Run the specs, then both gates and the autoloading check**

```bash
bundle exec rspec spec/requests/admin_reporting_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: **531 examples** (528 + 3), 0 failures, 6 pending; cucumber unchanged; `All is good!`.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/admin app/views/admin config/routes.rb config/locales spec/requests/admin_reporting_spec.rb
git commit -m "Add the superadmin stats screen"
```

---

### Task 3: The users screens

**Files:**
- Create: `app/controllers/admin/users_controller.rb`, `app/views/admin/users/index.html.erb`, `app/views/admin/users/show.html.erb`
- Modify: `config/routes.rb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/admin_reporting_spec.rb` (extend)

**Interfaces:**
- Consumes: `require_superadmin!`, and the `sign_in` helper already in the spec file from Task 2.
- Produces: `GET /admin/users` (`admin_users_path`) and `GET /admin/users/:id` (`admin_user_path`).

- [ ] **Step 1: Write the failing specs**

Append to `spec/requests/admin_reporting_spec.rb`, inside the existing top-level `describe`:

```ruby
  describe "the users list" do
    it "refuses an anonymous visitor" do
      get admin_users_path
      expect(response).not_to have_http_status(:ok)
    end

    it "refuses an ordinary signed-in user" do
      sign_in(ordinary)
      get admin_users_path
      expect(response).not_to have_http_status(:ok)
    end

    it "shows every user's identity and email to a superadmin" do
      other = create_user
      sign_in(superadmin)

      get admin_users_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(other.nickname)
      expect(response.body).to include(other.email)
    end

    # The contact details a player gave in order to play, not to be browsed.
    # They exist on the detail page; the point is that reading all of them
    # takes deliberate clicks.
    it "does not put contact details in the list" do
      other = create_user
      other.update!(:phone_number => "+995555123456")
      sign_in(superadmin)

      get admin_users_path

      expect(response.body).not_to include("+995555123456")
    end

    # This N+1 has been written into two consecutive plans on this project and
    # shipped once. It gets a test rather than a comment.
    it "keeps the query count flat as the number of users grows" do
      sign_in(superadmin)

      2.times { u = create_user; u.update!(:team => create_team) }
      small = count_queries { get admin_users_path }

      8.times { u = create_user; u.update!(:team => create_team) }
      large = count_queries { get admin_users_path }

      expect(large).to eq(small)
    end
  end

  describe "the user detail page" do
    it "refuses an ordinary signed-in user" do
      sign_in(ordinary)
      get admin_user_path(create_user)
      expect(response).not_to have_http_status(:ok)
    end

    it "shows contact details to a superadmin" do
      other = create_user
      other.update!(:phone_number => "+995555123456", :icq_number => "123456789")
      sign_in(superadmin)

      get admin_user_path(other)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("+995555123456")
      expect(response.body).to include("123456789")
    end
  end

  # Not because anyone would add them deliberately, but because a future
  # `<%= user.attributes %>` debugging line would leak them silently.
  describe "password material" do
    it "never appears on any reporting screen" do
      other = create_user
      sign_in(superadmin)

      [ admin_dashboard_path, admin_users_path, admin_user_path(other) ].each do |path|
        get path
        expect(response.body).not_to include(other.crypted_password.to_s) if other.crypted_password.present?
        expect(response.body).not_to include(other.salt.to_s) if other.salt.present?
      end
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_reporting_spec.rb
```

Expected: FAIL — undefined route helper `admin_users_path`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside the same `namespace :admin` block:

```ruby
    resources :users, only: [ :index, :show ]
```

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/admin/users_controller.rb
#
# Read-only, and deliberately split: the list carries identity and email, the
# detail page carries contact details. Nothing is hidden from the operator, but
# reading the whole membership's phone numbers takes deliberate clicks rather
# than one glance -- which is what matters once this role can be granted to a
# helper.
#
# crypted_password and salt are never passed to a view.
class Admin::UsersController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # :team is preloaded because the list renders one per row. Without it this
    # page issues a SELECT per user, which is the exact defect the all-games
    # console shipped with.
    @users = User.includes(:team).order(:created_at => :desc)
  end

  def show
    @user = User.includes(:team, :created_games).find(params[:id])
  end
end
```

- [ ] **Step 5: Write the list view**

```erb
<%# app/views/admin/users/index.html.erb %>
<h1><%= t("admin.users.index.title") %></h1>

<table class="admin-users">
  <tr>
    <th><%= t("admin.users.index.nickname") %></th>
    <th><%= t("admin.users.index.email") %></th>
    <th><%= t("admin.users.index.team") %></th>
    <th><%= t("admin.users.index.locale") %></th>
    <th><%= t("admin.users.index.signed_up") %></th>
    <th><%= t("admin.users.index.role") %></th>
  </tr>
  <% @users.each do |user| %>
    <tr>
      <td><%= link_to user.nickname, admin_user_path(user) %></td>
      <td><%= user.email %></td>
      <td><%= user.team&.name %></td>
      <td><%= user.locale %></td>
      <td><%= l(user.created_at, :format => :long) %></td>
      <td><%= t("admin.users.index.superadmin") if user.superadmin? %></td>
    </tr>
  <% end %>
</table>

<p><%= link_to t("admin.users.index.back"), admin_dashboard_path %></p>
```

Nicknames, emails and team names are user-written content and render verbatim; every label is chrome through `t()`.

- [ ] **Step 6: Write the detail view**

```erb
<%# app/views/admin/users/show.html.erb %>
<h1><%= @user.nickname %></h1>

<table class="admin-user">
  <tr><th><%= t("admin.users.show.email") %></th><td><%= @user.email %></td></tr>
  <tr><th><%= t("admin.users.show.phone") %></th><td><%= @user.phone_number %></td></tr>
  <tr><th><%= t("admin.users.show.jabber") %></th><td><%= @user.jabber_id %></td></tr>
  <tr><th><%= t("admin.users.show.icq") %></th><td><%= @user.icq_number %></td></tr>
  <tr><th><%= t("admin.users.show.date_of_birth") %></th><td><%= @user.date_of_birth %></td></tr>
  <tr><th><%= t("admin.users.show.team") %></th><td><%= @user.team&.name %></td></tr>
  <tr><th><%= t("admin.users.show.locale") %></th><td><%= @user.locale %></td></tr>
  <tr><th><%= t("admin.users.show.signed_up") %></th><td><%= l(@user.created_at, :format => :long) %></td></tr>
</table>

<h2><%= t("admin.users.show.authored_games") %></h2>
<%# There is no team history to show: users.team_id is one column, so the
    schema keeps no record of previous teams. Participation in games runs
    through the team rather than the user, so "games this person played" is
    not a question this schema answers directly. %>
<ul>
  <% @user.created_games.each do |game| %>
    <li><%= link_to game.name, game_path(game) %></li>
  <% end %>
</ul>

<p><%= link_to t("admin.users.show.back"), admin_users_path %></p>
```

- [ ] **Step 7: Add the chrome keys to all four locale files**

`config/locales/ru.yml`, under `admin:`:

```yaml
    users:
      index:
        title: "Игроки"
        nickname: "Ник"
        email: "E-mail"
        team: "Команда"
        locale: "Язык"
        signed_up: "Регистрация"
        role: "Роль"
        superadmin: "администратор"
        back: "К обзору"
      show:
        email: "E-mail"
        phone: "Телефон"
        jabber: "Jabber"
        icq: "ICQ"
        date_of_birth: "Дата рождения"
        team: "Команда"
        locale: "Язык"
        signed_up: "Регистрация"
        authored_games: "Созданные игры"
        back: "К списку игроков"
```

`config/locales/en.yml`:

```yaml
    users:
      index:
        title: "Players"
        nickname: "Nickname"
        email: "Email"
        team: "Team"
        locale: "Language"
        signed_up: "Registered"
        role: "Role"
        superadmin: "administrator"
        back: "Back to overview"
      show:
        email: "Email"
        phone: "Phone"
        jabber: "Jabber"
        icq: "ICQ"
        date_of_birth: "Date of birth"
        team: "Team"
        locale: "Language"
        signed_up: "Registered"
        authored_games: "Games created"
        back: "Back to players"
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values.

- [ ] **Step 8: Prove the N+1 guard discriminates**

Temporarily change the controller's `index` to `User.order(:created_at => :desc)` — dropping `includes(:team)` — and run:

```bash
bundle exec rspec spec/requests/admin_reporting_spec.rb -e "keeps the query count flat"
```

Expected: FAIL, with `large` exceeding `small`. Restore the `includes` and confirm it passes. **Record both numbers in your report.** A guard that passes either way is worse than no guard, and this project has shipped one.

- [ ] **Step 9: Run the specs, then both gates and the autoloading check**

```bash
bundle exec rspec spec/requests/admin_reporting_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: **538 examples** (531 + 7), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps; `All is good!`.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/admin app/views/admin config/routes.rb config/locales spec/requests/admin_reporting_spec.rb
git commit -m "Add the superadmin users list and detail page"
```

---

## Self-Review

**Spec coverage.** Games by status with the explicit precedence and the sum property (Task 1); `starts_at` nullability handled explicitly (Task 1); editing-locked counted separately (Task 1); headline counts and entry states as SQL aggregates (Task 2); the stats screen gated by `require_superadmin!` (Task 2); the users list carrying identity and email only, and the detail page carrying contact details (Task 3); `crypted_password` and `salt` absent from every screen, asserted across all three (Task 3); the query-count guard on the users list, with a mandated discrimination check (Task 3 Step 8); read-only throughout — every route added is a `GET`; no migration, because no task adds one.

**Explicitly out of scope, per the spec:** any query interface, user editing, role granting, `GamePassing` intervention, charts and export, pagination and search. No task builds them.

**Placeholder scan.** No "TBD" or "add validation". One step deliberately instructs the implementer to verify rather than trust: Task 3 Step 8's discrimination check. Two facts that bit earlier plans on this project are stated in the constraints rather than left to be rediscovered — the fixture password is `1234`, and there is no team history.

**Type consistency.** `Game.count_by_status` returns a Hash keyed `:withdrawn, :draft, :finished, :running, :scheduled` in Task 1 and is iterated with exactly those keys in Task 2's view and locale files. `Game.editing_locked_count` is used with that name in both. `admin_dashboard_path`, `admin_users_path` and `admin_user_path` are defined in Tasks 2–3 and cross-referenced consistently between the two views and the password-material spec.

**Running example counts.** 522 → 528 (T1) → 531 (T2) → 538 (T3). Cucumber stays at 234 scenarios / 2362 steps throughout; any change there is a regression, not a new feature.
