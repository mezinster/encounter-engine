# Operator Entries Console and Run-Scoped Logs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the superadmin a screen for admitting teams to a run, and make the log screens run-aware, fast and paged.

**Architecture:** Two independent halves sharing no file. **Part A (Tasks 1–2)** adds `Admin::GameEntriesController` and one console link. **Part B (Tasks 3–5)** gives the log screens a `?run=` parameter, removes the full log's per-cell query, and adds a hand-rolled pager to the two screens that grow.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec, sqlite in dev/test, PostgreSQL in production. No new gems.

**Spec:** `docs/superpowers/specs/2026-08-10-operator-entries-and-run-logs-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix every command with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any file under `features/`.** This plan touches none.
- **Cucumber must stay at exactly 232 scenarios (230 passed, 2 undefined) / 2342 steps** after every task. `features/logs/log.feature` and `features/games/game_full_log.feature` drive these screens.
- **The pager emits no markup at all when `total_pages <= 1`.** Same rule as the run switcher on a single-run game — and the equivalent rule has already been broken once in this programme.
- **Every new user-facing string needs a key in all seven locale files** (`ru,en,uk,ka,tr,be,pl`). `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity.
- **New audit actions need a label** under `admin.audit.index.action.*` in all seven files. The audit view falls back to the raw identifier, so a forgotten label fails nowhere — assert the identifier is **absent** from the log.
- **No new gem.** Pagination is hand-rolled (spec D3).
- **Do not change who may see a log.** `ensure_author` and `ensure_full_log_access` are untouched.
- **Hash-rocket style** (`:key => value`), comments in English, user-facing strings in Russian.
- Commit after every task.

---

# Part A — the entries console

### Task 1: The screen, and accept/reject

**Files:**
- Create: `app/controllers/admin/game_entries_controller.rb`
- Create: `app/views/admin/game_entries/index.html.erb`
- Modify: `config/routes.rb` (admin games block)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Modify: `spec/requests/admin_audit_spec.rb`
- Test: `spec/requests/admin_entries_console_spec.rb` (create)

**Interfaces:**
- Produces: `admin_game_entries_path(game)` → `GET /admin/games/:game_id/entries`; `accept_admin_game_entry_path(game, entry)` and `reject_admin_game_entry_path(game, entry)` → `POST …/entries/:id/accept|reject`. Task 2 links to the first.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/admin_entries_console_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Opening a run is an operator power but populating it was not: accept is
# behind ensure_author (which admits superadmins) while games/show gates the
# entries block on author_of? (which does not), so the action was permitted
# and the button never rendered.
describe "the operator's entries console", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:team)     { create_team(:captain => create_user) }
  let(:game) do
    g = create_game(:author => author, :is_draft => false, :max_team_number => 10)
    create_level(:game => g)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def pending_entry(run = game.current_run)
    GameEntry.create!(:game => game, :game_run => run, :team => team, :status => "new")
  end

  it "lists the current run's pending teams" do
    pending_entry
    sign_in(operator)

    get admin_game_entries_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(team.name)
  end

  # Admission belongs to a run. An operator must not be shown an applicant to
  # a cohort that has already been and gone.
  it "does not list an earlier run's entries" do
    old_team = create_team(:captain => create_user)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => old_team, :status => "new")
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
    pending_entry(game.current_run)
    sign_in(operator)

    get admin_game_entries_path(game)

    expect(response.body).to include(team.name)
    expect(response.body).not_to include(old_team.name)
  end

  it "accepts an application" do
    entry = pending_entry
    sign_in(operator)

    post accept_admin_game_entry_path(game, entry)

    expect(entry.reload.status).to eq("accepted")
    expect(response).to redirect_to(admin_game_entries_path(game))
  end

  it "rejects an application and frees its place" do
    entry = pending_entry
    game.current_run.update_column(:requested_teams_number, 1)
    sign_in(operator)

    post reject_admin_game_entry_path(game, entry)

    expect(entry.reload.status).to eq("rejected")
    expect(game.reload.requested_teams_number).to eq(0)
  end

  # THE production bug the guard exists for. Rejecting twice must not free a
  # second place: the counter would drift below what is actually taken and let
  # an extra team past max_team_number. Seen for real with a captain
  # double-clicking «Отозвать» -- see GameEntriesController#recall's comment.
  it "does not free a second place when rejected twice" do
    entry = pending_entry
    game.current_run.update_column(:requested_teams_number, 2)
    sign_in(operator)

    post reject_admin_game_entry_path(game, entry)
    post reject_admin_game_entry_path(game, entry)

    expect(game.reload.requested_teams_number).to eq(1)
  end

  it "refuses a player who is not a superadmin" do
    entry = pending_entry
    sign_in(author)

    post accept_admin_game_entry_path(game, entry)

    expect(response).to have_http_status(:unauthorized)
    expect(entry.reload.status).to eq("new")
  end

  # Scoped through the run, so an id belonging to another game or run 404s
  # rather than being acted on -- the same discipline as
  # Admin::TeamsController#set_captain looking members up through the team.
  it "404s on an entry from another game" do
    other = create_game(:author => author, :is_draft => false)
    stray = GameEntry.create!(:game => other, :game_run => other.current_run,
                              :team => team, :status => "new")
    sign_in(operator)

    expect {
      post accept_admin_game_entry_path(game, stray)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  describe "auditing" do
    it "records an acceptance against the game, naming the team" do
      entry = pending_entry
      sign_in(operator)

      expect { post accept_admin_game_entry_path(game, entry) }
        .to change(AdminAction, :count).by(1)

      row = AdminAction.newest_first.first
      expect(row.action).to eq("accept_entry")
      expect(row.target_type).to eq("Game")
      expect(row.details).to eq(team.name)
    end

    it "records a rejection" do
      entry = pending_entry
      sign_in(operator)

      post reject_admin_game_entry_path(game, entry)

      expect(AdminAction.newest_first.first.action).to eq("reject_entry")
    end

    it "writes nothing for a no-op second reject" do
      entry = pending_entry
      sign_in(operator)
      post reject_admin_game_entry_path(game, entry)

      expect { post reject_admin_game_entry_path(game, entry) }
        .not_to change(AdminAction, :count)
    end

    # The audit view falls back to the raw action name on a missing key, so
    # only asserting the identifier is ABSENT catches a forgotten label.
    it "renders sentences in the log, not raw action names" do
      entry = pending_entry
      sign_in(operator)
      post accept_admin_game_entry_path(game, entry)

      get admin_audit_index_path

      expect(response.body).to include(I18n.t("admin.audit.index.action.accept_entry"))
      expect(response.body).not_to include("accept_entry")
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_entries_console_spec.rb
```

Expected: FAIL with `NameError: undefined local variable or method 'admin_game_entries_path'`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside the admin `resources :games` block:

```ruby
    resources :games, only: [ :index ] do
      post "set_author", on: :member
      post "open_run",   on: :member

      # Nested under the game deliberately: free_place_of_team! is a method on
      # Game, and the redirect target is this screen, so both need the game in
      # scope regardless.
      resources :entries, only: [ :index ], controller: "game_entries" do
        member do
          post :accept
          post :reject
        end
      end
    end
```

- [ ] **Step 4: Add the locale keys**

Add an `entries:` block under `admin:` (a sibling of `games:`) and two audit labels, in all seven files.

`config/locales/ru.yml` — under `admin:`:
```yaml
    entries:
      title: "Заявки на игру «%{game}»"
      run: "Забег №%{ordinal}"
      pending: "Ожидают решения"
      accepted: "Приняты"
      none: "—"
      accept: "Принять"
      reject: "Отклонить"
      accepted_notice: "Команда принята: %{team}"
      rejected_notice: "Заявка отклонена: %{team}"
      back: "К списку игр"
```
and under `admin: → audit: → index: → action:`:
```yaml
          accept_entry: "Принял заявку команды"
          reject_entry: "Отклонил заявку команды"
```

`config/locales/en.yml`:
```yaml
    entries:
      title: "Applications for “%{game}”"
      run: "Run №%{ordinal}"
      pending: "Awaiting a decision"
      accepted: "Accepted"
      none: "—"
      accept: "Accept"
      reject: "Reject"
      accepted_notice: "Team accepted: %{team}"
      rejected_notice: "Application rejected: %{team}"
      back: "Back to the games list"
```
```yaml
          accept_entry: "Accepted a team's application"
          reject_entry: "Rejected a team's application"
```

`config/locales/uk.yml`:
```yaml
    entries:
      title: "Заявки на гру «%{game}»"
      run: "Забіг №%{ordinal}"
      pending: "Очікують рішення"
      accepted: "Прийняті"
      none: "—"
      accept: "Прийняти"
      reject: "Відхилити"
      accepted_notice: "Команду прийнято: %{team}"
      rejected_notice: "Заявку відхилено: %{team}"
      back: "До списку ігор"
```
```yaml
          accept_entry: "Прийняв заявку команди"
          reject_entry: "Відхилив заявку команди"
```

`config/locales/be.yml`:
```yaml
    entries:
      title: "Заяўкі на гульню «%{game}»"
      run: "Забег №%{ordinal}"
      pending: "Чакаюць рашэння"
      accepted: "Прынятыя"
      none: "—"
      accept: "Прыняць"
      reject: "Адхіліць"
      accepted_notice: "Каманда прынята: %{team}"
      rejected_notice: "Заяўка адхілена: %{team}"
      back: "Да спісу гульняў"
```
```yaml
          accept_entry: "Прыняў заяўку каманды"
          reject_entry: "Адхіліў заяўку каманды"
```

`config/locales/pl.yml`:
```yaml
    entries:
      title: "Zgłoszenia do gry „%{game}”"
      run: "Bieg nr %{ordinal}"
      pending: "Oczekują na decyzję"
      accepted: "Przyjęte"
      none: "—"
      accept: "Przyjmij"
      reject: "Odrzuć"
      accepted_notice: "Drużyna przyjęta: %{team}"
      rejected_notice: "Zgłoszenie odrzucone: %{team}"
      back: "Do listy gier"
```
```yaml
          accept_entry: "Przyjął zgłoszenie drużyny"
          reject_entry: "Odrzucił zgłoszenie drużyny"
```

`config/locales/tr.yml` — the suffix goes on a common noun, never on `%{team}` or `%{game}`:
```yaml
    entries:
      title: "«%{game}» adlı oyuna başvurular"
      run: "%{ordinal}. koşu"
      pending: "Karar bekliyor"
      accepted: "Kabul edildi"
      none: "—"
      accept: "Kabul et"
      reject: "Reddet"
      accepted_notice: "Takım kabul edildi: %{team}"
      rejected_notice: "Başvuru reddedildi: %{team}"
      back: "Oyun listesine dön"
```
```yaml
          accept_entry: "Bir takımın başvurusunu kabul etti"
          reject_entry: "Bir takımın başvurusunu reddetti"
```

`config/locales/ka.yml`:
```yaml
    entries:
      title: "განაცხადები თამაშზე «%{game}»"
      run: "გარბენი №%{ordinal}"
      pending: "ელოდება გადაწყვეტილებას"
      accepted: "მიღებულია"
      none: "—"
      accept: "მიღება"
      reject: "უარყოფა"
      accepted_notice: "გუნდი მიღებულია: %{team}"
      rejected_notice: "განაცხადი უარყოფილია: %{team}"
      back: "თამაშების სიაში"
```
```yaml
          accept_entry: "მიიღო გუნდის განაცხადი"
          reject_entry: "უარყო გუნდის განაცხადი"
```

- [ ] **Step 5: Add the controller**

Create `app/controllers/admin/game_entries_controller.rb`:

```ruby
# The operator's admission screen. Opening a run is a superadmin power, but
# populating it was not: GameEntriesController#accept is behind ensure_author,
# which DOES admit superadmins, while games/show.html.erb:47 gates the entries
# block on author_of?, which does NOT -- so the action was permitted and the
# button never rendered. The only routes were borrowing authorship or the
# database.
class Admin::GameEntriesController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!
  before_action :find_game
  before_action :find_entry, only: [ :accept, :reject ]

  def index
    @run = @game.current_run
    @pending  = GameEntry.of_run(@run).with_status("new").includes(:team)
    @accepted = GameEntry.of_run(@run).with_status("accepted").includes(:team)
  end

  def accept
    if @entry.status == "new"
      @entry.accept!
      record_admin_action("accept_entry", @game, @entry.team&.name)
    end

    redirect_to admin_game_entries_path(@game),
                :notice => t("admin.entries.accepted_notice", :team => @entry.team&.name)
  end

  # The `status == "new"` guard is load-bearing and copied verbatim from
  # GameEntriesController#reject, not simplified. Its comment there records the
  # failure: free_place_of_team! firing unconditionally lets a double-clicked
  # reject free a place that is not this entry's to free, and the counter then
  # drifts below what is actually taken, letting one extra team past
  # max_team_number. Seen in production with a captain double-clicking
  # «Отозвать».
  def reject
    if @entry.status == "new"
      @entry.reject!
      @game.free_place_of_team!
      record_admin_action("reject_entry", @game, @entry.team&.name)
    end

    redirect_to admin_game_entries_path(@game),
                :notice => t("admin.entries.rejected_notice", :team => @entry.team&.name)
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  # Looked up THROUGH the current run rather than by bare id: an entry
  # belonging to another game, or to an earlier run of this one, raises
  # RecordNotFound instead of being acted on. Same discipline as
  # Admin::TeamsController#set_captain finding its member through the team.
  def find_entry
    @entry = GameEntry.of_run(@game.current_run).find(params[:id])
  end
end
```

- [ ] **Step 6: Add the view**

Create `app/views/admin/game_entries/index.html.erb`:

```erb
<h1><%= t("admin.entries.title", :game => @game.name) %></h1>

<%# The run is named, so an operator cannot mistake which cohort they are
    admitting to. Admission is always to the CURRENT run -- nothing else in
    the application can address any other one. %>
<p><strong><%= t("admin.entries.run", :ordinal => @run.ordinal) %></strong></p>

<fieldset class="card">
  <legend><%= t("admin.entries.pending") %></legend>
  <% if @pending.empty? %>
    <p><%= t("admin.entries.none") %></p>
  <% else %>
    <ul class="game-list">
      <% @pending.each do |entry| %>
        <li>
          <%= entry.team&.name %>
          <div class="game-control">
            <%= button_to t("admin.entries.accept"),
                          accept_admin_game_entry_path(@game, entry),
                          :method => :post, :class => "btn" %>
            <%= button_to t("admin.entries.reject"),
                          reject_admin_game_entry_path(@game, entry),
                          :method => :post, :class => "btn btn--danger" %>
          </div>
        </li>
      <% end %>
    </ul>
  <% end %>
</fieldset>

<fieldset class="card">
  <legend><%= t("admin.entries.accepted") %></legend>
  <% if @accepted.empty? %>
    <p><%= t("admin.entries.none") %></p>
  <% else %>
    <ul class="game-list">
      <% @accepted.each do |entry| %>
        <li><%= entry.team&.name %></li>
      <% end %>
    </ul>
  <% end %>
</fieldset>

<p><%= link_to t("admin.entries.back"), admin_games_path %></p>
```

- [ ] **Step 7: Add the audit action to the enumerated list**

In `spec/requests/admin_audit_spec.rb`, inside `describe "the explicitly superadmin actions"`:

```ruby
    it "records accepting a team's application" do
      applicant = create_team(:captain => create_user)
      entry = GameEntry.create!(:game => game, :game_run => game.current_run,
                                :team => applicant, :status => "new")

      expect do
        post accept_admin_game_entry_path(game, entry)
      end.to change { AdminAction.count }.by(1)

      expect(AdminAction.newest_first.first.action).to eq("accept_entry")
    end
```

- [ ] **Step 8: Run the specs, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_entries_console_spec.rb spec/requests/admin_audit_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: PASS throughout; Cucumber **232 / 2342**.

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/controllers/admin/game_entries_controller.rb app/views/admin/game_entries config/locales spec/
git commit -m "Give the operator a screen for admitting teams

Opening a run was a superadmin power but populating it was not: accept
is behind ensure_author, which admits superadmins, while games/show
gates the entries block on author_of?, which does not -- so the action
was permitted and the button never rendered.

The reject guard is copied verbatim rather than simplified: without it
a double-clicked reject frees a place that is not that entry's to free,
and the counter drifts below what is taken. An example asserts the
second reject frees nothing."
```

---

### Task 2: The console link, with a pending count that costs one query

**Files:**
- Modify: `app/controllers/admin/games_controller.rb` (`index`)
- Modify: `app/views/admin/games/index.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/admin_entries_console_spec.rb` (extend)

**Interfaces:**
- Consumes: `admin_game_entries_path(game)` from Task 1.
- Produces: `@pending_entry_counts` — a `{ game_run_id => Integer }` hash for the listed games.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/admin_entries_console_spec.rb`, before the final `end`:

```ruby
  describe "the link on the games console" do
    it "shows the pending count for the current run" do
      pending_entry
      sign_in(operator)

      get admin_games_path

      expect(response.body).to include(admin_game_entries_path(game))
      expect(response.body).to include(I18n.t("admin.games.index.entries_link", :count => 1))
    end

    it "counts only the current run's applications" do
      GameEntry.create!(:game => game, :game_run => game.current_run,
                        :team => create_team(:captain => create_user), :status => "new")
      game.open_run!(:starts_at => 2.years.from_now,
                     :registration_deadline => 23.months.from_now,
                     :max_team_number => 10)
      game.reload
      sign_in(operator)

      get admin_games_path

      expect(response.body).to include(I18n.t("admin.games.index.entries_link", :count => 0))
    end

    # The console's own history makes this non-negotiable: it shipped with a
    # per-row COUNT, and Admin::GamesController#index's comment calls that "the
    # one query pattern a screen that lists *everything* can least afford".
    # Compares a small fixture against a larger one, so the assertion is about
    # the SLOPE being flat rather than a magic number.
    it "keeps the query count flat as the number of games grows" do
      sign_in(operator)

      def make_games_with_applications(count)
        count.times do
          g = create_game(:author => author, :is_draft => false)
          create_level(:game => g)
          GameEntry.create!(:game => g, :game_run => g.current_run,
                            :team => create_team(:captain => create_user), :status => "new")
        end
      end

      make_games_with_applications(2)
      small = count_queries { get admin_games_path }

      make_games_with_applications(6)
      large = count_queries { get admin_games_path }

      expect(large).to eq(small)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_entries_console_spec.rb -e "the link on the games console"
```

Expected: FAIL — `admin.games.index.entries_link` raises `I18n::MissingTranslationData`.

- [ ] **Step 3: Add the locale key**

Inside `admin: → games: → index:` in all seven files:

```yaml
# ru.yml
        entries_link: "Заявки (%{count})"
# en.yml
        entries_link: "Applications (%{count})"
# uk.yml
        entries_link: "Заявки (%{count})"
# be.yml
        entries_link: "Заяўкі (%{count})"
# pl.yml
        entries_link: "Zgłoszenia (%{count})"
# tr.yml
        entries_link: "Başvurular (%{count})"
# ka.yml
        entries_link: "განაცხადები (%{count})"
```

- [ ] **Step 4: Count the applications in one query**

In `app/controllers/admin/games_controller.rb#index`, after `@games` is assigned:

```ruby
    # ONE grouped query for the whole page, not one per row. :runs is already
    # preloaded above, so current_run costs nothing here -- and the comment on
    # the includes above records why a per-row count is the one pattern this
    # screen can least afford.
    @pending_entry_counts = GameEntry.with_status("new")
                                     .where(:game_run_id => @games.map { |g| g.current_run.id })
                                     .group(:game_run_id)
                                     .count
```

- [ ] **Step 5: Add the link**

In `app/views/admin/games/index.html.erb`, inside the control cell, immediately after the `edit` link:

```erb
          <%= link_to t("admin.games.index.entries_link",
                        :count => @pending_entry_counts.fetch(game.current_run.id, 0)),
                      admin_game_entries_path(game), :class => "btn" %>
```

- [ ] **Step 6: Run the specs, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_entries_console_spec.rb spec/requests/admin_console_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: PASS; Cucumber **232 / 2342**.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/admin/games_controller.rb app/views/admin/games/index.html.erb config/locales spec/
git commit -m "Link the entries console from the games list

One grouped query for every game on the page rather than a count per
row -- the console shipped with the per-row shape once already, and its
own comment calls that the one query pattern a screen listing
everything can least afford. A flat-slope guard pins it."
```

---

# Part B — run-scoped logs, without the N+1, paged

### Task 3: The log screens take a run

**Files:**
- Modify: `app/controllers/logs_controller.rb`
- Test: `spec/requests/run_scoped_logs_spec.rb` (create)

**Interfaces:**
- Produces: `@run` on every `LogsController` action; `?run=<ordinal>` on all four log URLs.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/run_scoped_logs_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The §9 deferral from phase 3: after a second run opens, an author could not
# review the first run's answers at all -- every log screen showed the current
# run and nothing else.
#
# No started-run guard applies to these screens (they are gated by
# ensure_author and ensure_full_log_access), so unlike the results page there
# is no run they will name but refuse to serve.
describe "logs scoped to a run", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end
  let(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A team with a passing and a log in the run that is current at the time.
  def team_playing(run, answer)
    team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => team, :game_run => run)
    create_log(:game => game, :level => level, :team => team,
               :game_run => run, :answer => answer)
    team
  end

  def open_and_start_second_run
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game.reload
  end

  it "shows the current run's answers in the live channel by default" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id)

    expect(response.body).to include("новыйкод")
    expect(response.body).not_to include("старыйкод")
  end

  it "shows an earlier run's answers when asked by ordinal" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id, :run => 1)

    expect(response.body).to include("старыйкод")
    expect(response.body).not_to include("новыйкод")
  end

  it "shows an earlier run in the full log too" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include("старыйкод")
    expect(response.body).not_to include("новыйкод")
  end

  # @teams was built from game_passings.game_id -- game-scoped -- so the full
  # log listed a column for every team that ever played, whichever run was
  # being shown.
  it "shows only the chosen run's teams as columns in the full log" do
    first_run = game.current_run
    old_team = team_playing(first_run, "старыйкод")
    open_and_start_second_run
    new_team = team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include(new_team.name)
    expect(response.body).not_to include(old_team.name)
  end

  it "falls back to the current run for an unknown ordinal" do
    first_run = game.current_run
    team_playing(first_run, "старыйкод")
    open_and_start_second_run
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id, :run => 99)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("новыйкод")
  end

  it "falls back for a malformed ordinal" do
    team_playing(game.current_run, "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id, :run => "не-число")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("новыйкод")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/run_scoped_logs_spec.rb
```

Expected: FAIL — `?run=1` shows the current run, and the full log lists both teams' columns.

- [ ] **Step 3: Resolve the run, and scope the queries to it**

In `app/controllers/logs_controller.rb`, add the filter after `find_game`:

```ruby
  before_action :find_run
```

and the method beside `find_game`:

```ruby
  # The ORDINAL, not the id: stable, human-readable, and meaningful in a URL
  # someone might share. Unknown or malformed falls back to the current run
  # rather than 404ing.
  #
  # Simply current_run as the default, unlike the results page: no started-run
  # guard applies to these screens, so there is no run this can choose that the
  # filters would then refuse.
  def find_run
    @run = @game.runs.find_by(:ordinal => params[:run].to_i) || @game.current_run
  end
```

Then replace `@game.current_run` with `@run` in all four actions, and scope the full log's teams to the run:

```ruby
  def show_live_channel
    @logs = Log.of_run(@run).includes(:team_record, :level_record)
  end
```

```ruby
    @logs = @level ? Log.of_run(@run).of_team(@team).of_level(@level) : Log.none
```

```ruby
  def show_game_log
    @logs = Log.of_run(@run).of_team(@team)
  end
```

```ruby
  def show_full_log
    @logs = Log.of_run(@run)
    # Level.of_game, deliberately: levels are the game's CONTENT and are shared
    # by every run of it. Only the answers belong to one running.
    @levels = Level.of_game(@game)
```

and, further down in `show_full_log`, the teams — **this is a scoping bug, not just a rename**:

```ruby
    # game_run_id, not game_id: scoped to the game this listed a column for
    # every team that ever played it, whichever run was being shown.
    @teams = Team.joins(:game_passings)
                 .where(:game_passings => { :game_run_id => @run.id }).distinct
```

- [ ] **Step 4: Run the spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/run_scoped_logs_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: PASS; Cucumber **232 / 2342**. The log screens are frozen-scenario territory, so Cucumber is the gate here.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/logs_controller.rb spec/requests/run_scoped_logs_spec.rb
git commit -m "Let the log screens show an earlier run

The §9 deferral from phase 3: once a second run opened, the first run's
answers were unreachable. All four screens now take ?run=<ordinal>,
falling back to the current run.

The full log's team columns were scoped to the GAME, so it listed a
column for every team that ever played whichever run was shown. Now
scoped to the run."
```

---

### Task 4: The full log stops querying per cell

**Files:**
- Modify: `app/controllers/logs_controller.rb` (`show_full_log`)
- Modify: `app/views/logs/show_full_log.html.erb`
- Test: `spec/requests/full_log_queries_spec.rb` (create)

**Interfaces:**
- Consumes: `@run` from Task 3.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/full_log_queries_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# show_full_log renders @levels as rows and @teams as columns, and called
# @logs.of_team(team).of_level(level) in each cell. @logs was an UNLOADED
# relation, so that was one query per cell -- for «Викторина» as it stood,
# 77 levels x 3 teams ≈ 231 queries on one page load.
#
# Asserted as a SLOPE rather than a magic number, the same shape
# spec/requests/admin_console_spec.rb uses: a count pinned to an exact value
# breaks on any unrelated query added elsewhere, and says nothing about
# whether it grows.
describe "the full log's query count", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def add_levels_with_logs(count, team)
    count.times do
      level = create_level(:game => game)
      create_log(:game => game, :level => level, :team => team,
                 :game_run => game.current_run, :answer => "код")
    end
  end

  it "does not grow with the number of levels" do
    team = create_team(:captain => create_user)
    create_game_passing(:level => create_level(:game => game), :team => team,
                        :game_run => game.current_run)
    sign_in(author)

    add_levels_with_logs(2, team)
    small = count_queries { get show_full_log_path(:game_id => game.id) }

    add_levels_with_logs(8, team)
    large = count_queries { get show_full_log_path(:game_id => game.id) }

    expect(large).to eq(small)
  end

  it "still renders every answer" do
    team = create_team(:captain => create_user)
    level = create_level(:game => game)
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)
    create_log(:game => game, :level => level, :team => team,
               :game_run => game.current_run, :answer => "видимыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include("видимыйкод")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/full_log_queries_spec.rb
```

Expected: the slope example FAILs — `large` exceeds `small` by roughly the number of added levels.

- [ ] **Step 3: Load the logs once**

In `app/controllers/logs_controller.rb#show_full_log`:

```ruby
    # Loaded, not a relation. The view groups these in Ruby; leaving it lazy is
    # what produced one query per level x team cell.
    @logs = Log.of_run(@run).to_a
```

- [ ] **Step 4: Group in Ruby instead of re-querying**

In `app/views/logs/show_full_log.html.erb`, at the very top of the file (before the `<h1>`):

```erb
<%# One pass over the loaded logs, keyed by the cell that renders them. This
    replaced @logs.of_team(team).of_level(level) inside the levels x teams
    loops, which re-queried per cell because @logs was an unloaded relation --
    77 levels x 3 teams ≈ 231 queries for «Викторина». %>
<% logs_by_cell = @logs.group_by { |log| [ log.team_id, log.level_id ] } %>
```

and replace the per-cell lookup:

```erb
          <% team_logs = logs_by_cell.fetch([ team.id, level.id ], []) %>
```

- [ ] **Step 5: Run the spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/full_log_queries_spec.rb spec/requests/full_log_scope_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: PASS; Cucumber **232 / 2342**. `full_log_scope_spec.rb` is the one that pins *which* rows appear, so it must stay green alongside the count.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/logs_controller.rb app/views/logs/show_full_log.html.erb spec/requests/full_log_queries_spec.rb
git commit -m "Stop the full log querying once per cell

@logs was an unloaded relation and the view called
@logs.of_team(team).of_level(level) inside the levels x teams loops, so
the page issued one query per cell -- about 231 for «Викторина» as it
stands. Loaded once and grouped in Ruby.

Pinned as a slope rather than a number: an exact count breaks on any
unrelated query added elsewhere and says nothing about growth."
```

---

### Task 5: Pagination for the two screens that grow

**Files:**
- Create: `app/controllers/concerns/pagination.rb`
- Create: `app/views/shared/_pager.html.erb`
- Modify: `app/controllers/logs_controller.rb`
- Modify: `app/views/logs/show_full_log.html.erb`, `app/views/logs/show_live_channel.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/log_pagination_spec.rb` (create)

**Interfaces:**
- Consumes: `@run` from Task 3, `@logs` loaded from Task 4.
- Produces: `page_of(scope, requested, :per => n)` → `[records, current_page, total_pages]`; `@page` and `@total_pages` on the paged actions.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/log_pagination_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

describe "paging the log screens", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end
  let(:team) { create_team(:captain => create_user) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    create_game_passing(:level => create_level(:game => game), :team => team,
                        :game_run => game.current_run)
  end

  describe "the full log, paged by level" do
    def add_levels(count)
      count.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    end

    it "shows only the first page of levels" do
      add_levels(25)
      sign_in(author)

      get show_full_log_path(:game_id => game.id)

      expect(response.body).to include("Уровень 100")
      expect(response.body).not_to include("Уровень 124")
    end

    it "shows the rest on page two" do
      add_levels(25)
      sign_in(author)

      get show_full_log_path(:game_id => game.id, :page => 2)

      expect(response.body).to include("Уровень 124")
      expect(response.body).not_to include("Уровень 100")
    end

    # THE frozen-scenario guard. features/logs/log.feature and
    # features/games/game_full_log.feature render this page; a pager on a
    # single-page log would change what they see.
    it "renders no pager at all when everything fits on one page" do
      add_levels(3)
      sign_in(author)

      get show_full_log_path(:game_id => game.id)

      expect(response.body).not_to include(I18n.t("shared.pager.next"))
      expect(response.body).not_to include(I18n.t("shared.pager.previous"))
    end
  end

  describe "the live channel, paged newest first" do
    def add_logs(count)
      level = create_level(:game => game)
      count.times do |i|
        create_log(:game => game, :level => level, :team => team,
                   :game_run => game.current_run,
                   :answer => "код#{i + 100}", :time => i.minutes.ago)
      end
    end

    # Newest first is what it ALREADY rendered: its comparator returned 1 when
    # left.time <= right.time. Moving the sort into SQL must not reverse a page
    # a frozen scenario reads.
    it "puts the newest answer first" do
      add_logs(3)
      sign_in(author)

      get show_live_channel_path(:game_id => game.id)

      expect(response.body.index("код100")).to be < response.body.index("код102")
    end

    it "pages at fifty" do
      add_logs(55)
      sign_in(author)

      get show_live_channel_path(:game_id => game.id)

      expect(response.body).to include(I18n.t("shared.pager.next"))
    end

    it "renders no pager for a quiet game" do
      add_logs(3)
      sign_in(author)

      get show_live_channel_path(:game_id => game.id)

      expect(response.body).not_to include(I18n.t("shared.pager.next"))
    end
  end

  # Same forgiving rule as ?run=: a stale or hand-edited URL shows page one
  # rather than an empty table or a 500.
  it "clamps an out-of-range page to the last one" do
    25.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :page => 999)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Уровень 124")
  end

  it "clamps a malformed page to the first one" do
    25.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :page => "не-число")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Уровень 100")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/log_pagination_spec.rb
```

Expected: FAIL — `shared.pager.next` raises `I18n::MissingTranslationData` and every level renders on one page.

- [ ] **Step 3: Add the locale keys**

At the top level of each file, as a sibling of the other top-level blocks:

```yaml
# ru.yml
  shared:
    pager:
      previous: "‹ Назад"
      next: "Далее ›"
      position: "%{current} из %{total}"
# en.yml
  shared:
    pager:
      previous: "‹ Previous"
      next: "Next ›"
      position: "%{current} of %{total}"
# uk.yml
  shared:
    pager:
      previous: "‹ Назад"
      next: "Далі ›"
      position: "%{current} з %{total}"
# be.yml
  shared:
    pager:
      previous: "‹ Назад"
      next: "Далей ›"
      position: "%{current} з %{total}"
# pl.yml
  shared:
    pager:
      previous: "‹ Wstecz"
      next: "Dalej ›"
      position: "%{current} z %{total}"
# tr.yml
  shared:
    pager:
      previous: "‹ Geri"
      next: "İleri ›"
      position: "%{total} içinde %{current}"
# ka.yml
  shared:
    pager:
      previous: "‹ უკან"
      next: "წინ ›"
      position: "%{current} / %{total}"
```

**If a top-level `shared:` key already exists in a file, merge into it rather than adding a second one** — a duplicate key silently wins over the first in YAML.

- [ ] **Step 4: Add the pagination concern**

Create `app/controllers/concerns/pagination.rb`:

```ruby
# A page of a relation, hand-rolled rather than a gem: this is needed on two
# screens, and the codebase deliberately hand-rolls small things and records
# why (the countdown plural rules, AnsweredQuestionsCoder). The full log also
# pages LEVELS rather than the rows it lists, which sits awkwardly on a gem's
# idiom.
module Pagination
  extend ActiveSupport::Concern

  private

  # Returns [records, current_page, total_pages].
  #
  # The requested page is clamped into 1..total_pages, so an out-of-range or
  # malformed ?page= lands on a real page rather than an empty table or a 500 --
  # the same forgiving rule ?run= follows. to_i makes "не-число" zero, which
  # clamps up to 1.
  def page_of(scope, requested, per:)
    total = (scope.count.to_f / per).ceil
    total = 1 if total < 1

    current = requested.to_i
    current = 1 if current < 1
    current = total if current > total

    [ scope.offset((current - 1) * per).limit(per), current, total ]
  end
end
```

- [ ] **Step 5: Add the pager partial**

Create `app/views/shared/_pager.html.erb`:

```erb
<%# Nothing at all on a single page. features/logs/log.feature and
    features/games/game_full_log.feature render these screens, and a pager
    where there was none would change what they read -- the same rule the run
    switcher follows for a single-run game.

    The href is built from request.path plus the existing query parameters, so
    ?run= survives paging and vice versa. %>
<% if total > 1 %>
  <p class="pager">
    <% if current > 1 %>
      <%= link_to t("shared.pager.previous"),
                  "#{request.path}?#{request.query_parameters.merge("page" => current - 1).to_query}" %>
    <% end %>
    <%= t("shared.pager.position", :current => current, :total => total) %>
    <% if current < total %>
      <%= link_to t("shared.pager.next"),
                  "#{request.path}?#{request.query_parameters.merge("page" => current + 1).to_query}" %>
    <% end %>
  </p>
<% end %>
```

- [ ] **Step 6: Page the two screens**

In `app/controllers/logs_controller.rb`, include the concern beside the others:

```ruby
  include Pagination
```

`show_live_channel` — the sort moves into SQL, in the order it already rendered:

```ruby
  # order(:time => :desc) is the order this ALREADY produced: the view's
  # comparator returned 1 when left.time <= right.time, i.e. newest first.
  # Doing it in SQL is what lets the page stop loading every log for the run.
  def show_live_channel
    scope = Log.of_run(@run).includes(:team_record, :level_record).order(:time => :desc)
    @logs, @page, @total_pages = page_of(scope, params[:page], :per => 50)
  end
```

`show_full_log` — pages the **levels**, and loads only that page's logs:

```ruby
  def show_full_log
    # Level.of_game, deliberately: levels are the game's CONTENT and are shared
    # by every run of it. Only the answers belong to one running.
    @levels, @page, @total_pages = page_of(Level.of_game(@game).order(:position),
                                           params[:page], :per => 20)

    # Only this page's levels, so the grouped load shrinks with the page.
    @logs = Log.of_run(@run).where(:level_id => @levels.map(&:id)).to_a
```

**The rest of `show_full_log` is unchanged** — the run-scoped `@teams` assignment from Task 3 and its comment stay exactly as they are, below these lines.

In `app/views/logs/show_live_channel.html.erb`, delete the Ruby sort block and iterate `@logs` directly:

```erb
    <% @logs.each do |log| %>
```

and add the pager at the end of both views, after the closing `</div>` of the table wrapper:

```erb
<%= render "shared/pager", :current => @page, :total => @total_pages %>
```

- [ ] **Step 7: Run the spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/log_pagination_spec.rb spec/requests/full_log_queries_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: PASS; Cucumber **232 / 2342**; `All is good!`.

If Cucumber moves, the pager is rendering on a single page — that is the failure this task is most likely to produce.

- [ ] **Step 8: Boot the production environment**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u SMTP_PASSWORD=p \
  SMTP_ADDRESS=s MAIL_FROM=m@e.com DATABASE_URL="sqlite3:/tmp/probe.sqlite3" \
  bin/rails runner 'puts "ok"'
rm -f /tmp/probe.sqlite3
```

Expected: `ok`.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/concerns/pagination.rb app/views/shared/_pager.html.erb app/controllers/logs_controller.rb app/views/logs config/locales spec/
git commit -m "Page the full log and the live channel

Hand-rolled: two screens do not justify a dependency, and the full log
pages LEVELS rather than the rows it lists. An out-of-range or
malformed ?page= clamps to a real page, the same forgiving rule ?run=
follows.

The live channel's sort moves into SQL in the order it already
rendered -- its comparator returned 1 when left.time <= right.time,
newest first -- so a page frozen scenarios read is unchanged. The pager
emits nothing at all on a single page, for the same reason."
```

---

## Notes for the implementer

**Two independent halves.** Tasks 1–2 (entries console) and Tasks 3–5 (logs) share no file. Either can be merged without the other.

**Three things that look wrong and are not:**

1. **The reject guard is copied verbatim, not simplified.** Without `if @entry.status == "new"`, a double-clicked reject frees a place that is not that entry's to free. Production saw this.
2. **`@logs` becomes `.to_a` in `show_full_log`.** That is the N+1 fix, not laziness — the view groups in Ruby.
3. **The pager renders nothing on a single page.** That is a requirement, not an optimisation: frozen scenarios read these pages.

**Do not deploy while a game is running.** «Викторина» had a live run on 2026-08-10; a deploy cuts traffic over mid-session.
