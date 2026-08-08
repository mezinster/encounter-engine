# Team Membership Phase 2 — Captaincy Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin reassign any team's captain from the admin console, and let a captain hand over voluntarily from the team room — the two surfaces that make phase 1's `Team#set_captain!` reachable.

**Architecture:** A net-new `Admin::TeamsController` (the admin console has no team management at all today), plus one member action on the existing `TeamsController`. Both call `Team#set_captain!` and nothing else writes `captain_id`. A new `Team#in_live_race?` predicate powers the mid-race refusal that applies to the captain's self-service path but deliberately **not** to the superadmin's.

**Spec:** `docs/superpowers/specs/2026-08-08-team-membership-programme-design.md` — sub-project S1, decisions D1 and D2.

**Depends on:** phase 1 (PR #43) being merged. It provides `Team#set_captain!(member)`, which raises `ArgumentError` for a non-member, and the validation refusing a captain owned by another team.

**Tech Stack:** Rails 8, RSpec request/controller specs, sqlite test DB, Cucumber acceptance suite.

## Global Constraints

- **Never edit `features/**/*.feature`.** Step definitions are fair game. Assume no owner authorisation is granted.
- Run every command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` — Ruby is not on `PATH` in non-login shells.
- New i18n keys go in **all four** of `config/locales/{ru,en,uk,ka}.yml`; `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity. UI strings are Russian; code and comments are English.
- Hash rockets (`:key => value`) are the house style.
- Fixtures are plain helpers in `spec/spec_helpers/fixtures_helper.rb` — **no FactoryBot**.
- **This app has no Turbo and no rails-ujs.** A `link_to ..., method: :post` silently issues a GET. Every mutating control must be a real form — `button_to`, or `form_with` carrying a `select`. There are existing `button_to` call sites to copy; do not invent a link-based one.
- **Re-measure both suite baselines on your own branch.** Master moves under this programme — it moved three times during phase 1 (#36, #40, #42). Rebase *before* the full-suite run, not after.
- **Break every guard-style assertion and watch it fail before trusting it.** Phase 1 found one of its own assertions unreachable this way (see that plan's post-implementation notes).

---

### Task 1: `Team#in_live_race?`

The predicate the self-service handover guards on. Built first because Task 4 cannot be written without it.

**Files:**
- Modify: `app/models/team.rb` (public method, beside `set_captain!`)
- Test: create `spec/models/team/in_live_race_spec.rb`

**Interfaces:**
- Consumes: `Team#game_passings` (the `has_many` added by #40), `GamePassing#status`, `GamePassing#finished_at`.
- Produces: **`Team#in_live_race?`** → true while the team holds a `GamePassing` it has neither finished nor left and the author has not ended. Task 4 refuses handover when it is true.

- [ ] **Step 1: Confirm the status semantics before writing the spec**

Read `app/models/game_passing.rb` and verify all four of these, rather than trusting this plan:
`status` is `nil` while playing; `exit!` sets `"exited"`; `end!` sets `"ended"`; `finished_at` is set when the team completes the last level and the status stays `nil`. If any differs, stop and re-derive the predicate.

- [ ] **Step 2: Write the failing spec**

Create `spec/models/team/in_live_race_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Powers the mid-race refusal on captain self-service handover (D1 of
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md).
# Deliberately NOT applied to the superadmin path: the abandoned-captain
# problem is most acute mid-race, because quitting is itself captain-only.
RSpec.describe Team, "#in_live_race?" do
  it "is false for a team that has never entered a game" do
    team = create_team(:captain => create_user)

    expect(team.in_live_race?).to be false
  end

  it "is true while a passing is under way" do
    team = create_team(:captain => create_user)
    create_game_passing(:team => team, :level => create_level)

    expect(team.reload.in_live_race?).to be true
  end

  it "is false once the team has quit the race" do
    team = create_team(:captain => create_user)
    passing = create_game_passing(:team => team, :level => create_level)
    passing.exit!

    expect(team.reload.in_live_race?).to be false
  end

  it "is false once the author has ended the game" do
    team = create_team(:captain => create_user)
    passing = create_game_passing(:team => team, :level => create_level)
    passing.end!

    expect(team.reload.in_live_race?).to be false
  end

  # A finished passing keeps a nil status, so finished_at has to be checked
  # separately -- without that this would report a team that crossed the
  # line hours ago as still racing.
  it "is false once the team has finished" do
    team = create_team(:captain => create_user)
    passing = create_game_passing(:team => team, :level => create_level)
    passing.update!(:finished_at => Time.now)

    expect(team.reload.in_live_race?).to be false
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec rspec spec/models/team/in_live_race_spec.rb`
Expected: **5 failures, all `NoMethodError: undefined method 'in_live_race?'`.**

- [ ] **Step 4: Implement**

In `app/models/team.rb`, as a public method directly below `set_captain!`:

```ruby
  # True while the team is in a race that is still running for them.
  #
  # Guards captain self-service handover (see TeamsController#hand_over):
  # "Сойти с дистанции" is captain-only, so moving the role mid-race moves
  # that button from one player's screen to another's while the run is
  # live, and a new captain who does not understand the state can burn a
  # limited registration slot through Game#reserve_place_for_team! /
  # free_place_of_team!.
  #
  # Deliberately NOT consulted by the superadmin path. The abandoned-captain
  # case is most acute mid-race, because quitting is itself captain-only, so
  # refusing rescue exactly when it is needed is the wrong trade -- D1 of the
  # design.
  #
  # status is nil while playing; exit! sets "exited" and end! sets "ended".
  # finished_at is checked separately because a finished passing keeps a nil
  # status.
  def in_live_race?
    game_passings.any? { |passing| passing.status.nil? && passing.finished_at.nil? }
  end
```

- [ ] **Step 5: Run to verify it passes, then mutate**

Run: `bundle exec rspec spec/models/team/in_live_race_spec.rb` — expected 5 examples, 0 failures.

Then drop `&& passing.finished_at.nil?` and re-run: the "is false once the team has finished" example must fail. Restore it. If it does not fail, the fixture never set `finished_at` and the example is vacuous — fix the fixture, not the implementation.

- [ ] **Step 6: Commit**

```bash
git add app/models/team.rb spec/models/team/in_live_race_spec.rb
git commit -m "Add Team#in_live_race?, the mid-race guard for captaincy handover"
```

---

### Task 2: `Admin::TeamsController#index` — the listing

**Files:**
- Create: `app/controllers/admin/teams_controller.rb`
- Create: `app/views/admin/teams/index.html.erb`
- Modify: `config/routes.rb` (the `namespace :admin` block, beside `resources :games, only: [ :index ]`)
- Modify: `app/views/admin/dashboard/show.html.erb` (nav link, beside the existing all_games / audit_log links)
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: create `spec/requests/admin_teams_spec.rb`

**Interfaces:**
- Consumes: `SecurityFilters#require_superadmin!`, `Team#captain`, `Team#members`.
- Produces: `admin_teams_path` (GET). Task 3 adds the member action onto the same resource.

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/admin_teams_spec.rb`, following `spec/requests/admin_console_spec.rb`'s style (read it first — reuse its `sign_in` helper shape and its `let` bindings):

```ruby
require "rails_helper"

# The admin console had no team management at all before this --
# app/controllers/admin/ was audit, dashboard, games, users. See
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md, S1.
describe "the admin teams console", type: :request do
  let(:captain)    { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). create_user sets the
  # password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an anonymous visitor" do
    get admin_teams_path
    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(login_path)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(create_user)
    get admin_teams_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "lists every team with its captain and members" do
    team = create_team(:captain => captain)
    member = create_user
    team.members << member
    sign_in(superadmin)

    get admin_teams_path

    expect(response.body).to include(team.name)
    expect(response.body).to include(captain.nickname)
    expect(response.body).to include(member.nickname)
  end

  # A captainless team is a valid state and is exactly the one an operator
  # opens this screen to repair, so it must render rather than 500.
  it "renders a team that has no captain" do
    orphan = create_team
    sign_in(superadmin)

    get admin_teams_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(orphan.name)
  end

  # N+1 guard, mirroring the one in admin_console_spec: the view renders the
  # captain and the member list per row. Compares a small fixture against a
  # larger one so the assertion is about the SLOPE, not a magic number.
  it "keeps the query count flat as the number of teams grows" do
    sign_in(superadmin)
    2.times { create_team(:captain => create_user) }
    small = count_queries { get admin_teams_path }

    6.times { create_team(:captain => create_user) }
    large = count_queries { get admin_teams_path }

    expect(large).to be <= small + 1
  end
end
```

`count_queries` is a shared helper in `spec/support/query_counter.rb` (verified), so it needs no local definition. Note `spec/requests/games_listing_spec.rb:184` defines a second one locally — ignore that copy; do not add a third.

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/admin_teams_spec.rb`
Expected: all examples fail on `NameError: undefined local variable or method 'admin_teams_path'` — the route does not exist yet.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside `namespace :admin do`, directly after `resources :games, only: [ :index ]`:

```ruby
    resources :teams, only: [ :index ]
```

- [ ] **Step 4: Add the controller**

Create `app/controllers/admin/teams_controller.rb`:

```ruby
# Unlike Admin::GamesController, which is read-only because editing rides the
# author's own forms, this console owns a write: reassigning a captain. There
# is no author-facing captaincy editor to ride -- nothing outside
# TeamsController#create has ever set captain_id -- so the operation has to
# live here. See docs/superpowers/specs/
# 2026-08-08-team-membership-programme-design.md, S1.
class Admin::TeamsController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # captain and members are both rendered per row, so both are preloaded.
    # Without them this screen issues two extra queries per team -- the
    # pattern Admin::GamesController's comment calls out as the one a listing
    # of everything can least afford.
    @teams = Team.includes(:captain, :members).order(:name)
  end
end
```

- [ ] **Step 5: Add the view**

Create `app/views/admin/teams/index.html.erb`, mirroring the structure of `app/views/admin/games/index.html.erb` (read it first and match its table/`data-label` conventions):

```erb
<h2><%= t("admin.teams.index.title") %></h2>

<div class="table-wrap">
<table class="table--cards">
  <thead>
    <tr>
      <th><%= t("admin.teams.index.name") %></th>
      <th><%= t("admin.teams.index.captain") %></th>
      <th><%= t("admin.teams.index.members") %></th>
    </tr>
  </thead>
  <tbody>
  <% @teams.each do |team| %>
    <tr>
      <td data-label="<%= t("admin.teams.index.name") %>"><%= team.name %></td>
      <td data-label="<%= t("admin.teams.index.captain") %>">
        <%= team.captain&.nickname || t("admin.teams.index.no_captain") %>
      </td>
      <td data-label="<%= t("admin.teams.index.members") %>">
        <%= team.members.map(&:nickname).join(", ") %>
      </td>
    </tr>
  <% end %>
  </tbody>
</table>
</div>
```

- [ ] **Step 6: Add the nav link and the locale keys**

In `app/views/admin/dashboard/show.html.erb`, beside the existing `all_games` / `audit_log` links:

```erb
<p><%= link_to t("admin.dashboard.show.all_teams"), admin_teams_path %></p>
```

Locale keys, in all four files, under `admin:` (place `teams:` beside the existing `games:` block, and `all_teams` beside `all_games` in `dashboard.show`):

`ru.yml`
```yaml
        all_teams: "Все команды"
```
```yaml
      teams:
        index:
          title: "Команды"
          name: "Название"
          captain: "Капитан"
          members: "Состав"
          no_captain: "нет капитана"
```

`en.yml`
```yaml
        all_teams: "All teams"
```
```yaml
      teams:
        index:
          title: "Teams"
          name: "Name"
          captain: "Captain"
          members: "Members"
          no_captain: "no captain"
```

`uk.yml`
```yaml
        all_teams: "Усі команди"
```
```yaml
      teams:
        index:
          title: "Команди"
          name: "Назва"
          captain: "Капітан"
          members: "Склад"
          no_captain: "немає капітана"
```

`ka.yml`
```yaml
        all_teams: "ყველა გუნდი"
```
```yaml
      teams:
        index:
          title: "გუნდები"
          name: "სახელი"
          captain: "კაპიტანი"
          members: "შემადგენლობა"
          no_captain: "კაპიტანი არ არის"
```

- [ ] **Step 7: Run the spec and the i18n parity spec**

Run: `bundle exec rspec spec/requests/admin_teams_spec.rb spec/i18n_spec.rb`
Expected: all pass. If the N+1 example fails, the `includes` is not covering what the view reads — fix the preload, not the assertion.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/admin/teams_controller.rb app/views/admin/teams config/routes.rb app/views/admin/dashboard/show.html.erb config/locales spec/requests/admin_teams_spec.rb
git commit -m "Add a superadmin teams console"
```

---

### Task 3: `Admin::TeamsController#set_captain` — the superadmin reassignment

**Files:**
- Modify: `app/controllers/admin/teams_controller.rb`
- Modify: `app/views/admin/teams/index.html.erb` (the control column)
- Modify: `config/routes.rb`
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: extend `spec/requests/admin_teams_spec.rb`

**Interfaces:**
- Consumes: `Team#set_captain!` (phase 1), `record_admin_action` (`app/controllers/concerns/admin_audit.rb`).
- Produces: `set_captain_admin_team_path(team)` (POST, param `member_id`).

- [ ] **Step 1: Write the failing specs**

Append to `spec/requests/admin_teams_spec.rb`:

```ruby
  describe "reassigning a captain" do
    it "moves captaincy to another member and records an audit entry" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor
      sign_in(superadmin)

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(successor)
      expect(response).to redirect_to(admin_teams_path)
      action = AdminAction.order(:id).last
      expect(action.action).to eq("set_captain")
      expect(action.target_id).to eq(team.id)
    end

    it "rescues a captainless team" do
      orphan = create_team
      member = create_user
      orphan.members << member
      sign_in(superadmin)

      post set_captain_admin_team_path(orphan), :params => { :member_id => member.id }

      expect(orphan.reload.captain).to eq(member)
    end

    # Per D1 the superadmin path is deliberately allowed mid-race, unlike the
    # captain's own handover. This pins that asymmetry so nobody "fixes" it
    # into consistency later.
    it "is allowed while the team is in a live race" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor
      create_game_passing(:team => team, :level => create_level)
      sign_in(superadmin)

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(successor)
    end

    # The strict-scoping test. member_id is looked up THROUGH team.members, so
    # a crafted id belonging to somebody else's team cannot be installed --
    # and cannot be stolen, which is what Team's validation would otherwise
    # have to catch on its own.
    it "refuses a member_id belonging to another team, changing nothing" do
      team = create_team(:captain => captain)
      outsider = create_user
      other_team = create_team(:captain => outsider)
      sign_in(superadmin)

      post set_captain_admin_team_path(team), :params => { :member_id => outsider.id }

      expect(team.reload.captain).to eq(captain)
      expect(outsider.reload.team).to eq(other_team)
    end

    it "refuses an ordinary signed-in user" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor
      sign_in(create_user)

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(captain)
    end

    it "refuses an anonymous visitor" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(captain)
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/requests/admin_teams_spec.rb`
Expected: the six new examples fail on `undefined ... set_captain_admin_team_path`. The Task 2 examples still pass.

- [ ] **Step 3: Add the route**

Change the admin teams resource to:

```ruby
    resources :teams, only: [ :index ] do
      post "set_captain", on: :member
    end
```

- [ ] **Step 4: Add the action**

In `app/controllers/admin/teams_controller.rb`:

```ruby
  def set_captain
    team = Team.find(params[:id])
    # Looked up THROUGH team.members, not User.find: a crafted member_id
    # belonging to another team resolves to nil and is refused here, so it
    # never reaches set_captain! and never risks the theft path at all. Same
    # scoping discipline as GameEntriesController#ensure_captain_of_target_team.
    member = team.members.find_by(:id => params[:member_id])

    if member.nil?
      redirect_to admin_teams_path, :alert => t("admin.teams.not_a_member") and return
    end

    team.set_captain!(member)
    record_admin_action("set_captain", team, member.nickname)
    redirect_to admin_teams_path,
                :notice => t("admin.teams.captain_set", :nickname => member.nickname)
  end
```

`set_captain!`'s own `ArgumentError` is unreachable from here because membership is already guaranteed by the scoped lookup. That is deliberate belt-and-braces, not redundancy: the model stays safe for any future caller that is less careful.

- [ ] **Step 5: Add the control to the view**

Add a fourth column. **A `select` cannot ride `button_to`, and this app has no Turbo or UJS**, so use a plain form:

```erb
      <td>
        <% if team.members.any? %>
          <%= form_with url: set_captain_admin_team_path(team), method: :post do %>
            <%= select_tag :member_id,
                           options_from_collection_for_select(team.members, :id, :nickname, team.captain_id) %>
            <%= submit_tag t("admin.teams.index.set_captain"), :class => "btn" %>
          <% end %>
        <% end %>
      </td>
```

Add `<th><%= t("admin.teams.index.actions") %></th>` to the header row to match.

- [ ] **Step 6: Add the locale keys**

In all four files — button/column labels under `admin.teams.index`, flash messages under `admin.teams`, and the audit label beside the existing `admin.audit.index.action` entries:

`ru.yml`: `set_captain: "Назначить капитаном"`, `actions: "Действия"`, `captain_set: "Капитаном команды назначен %{nickname}"`, `not_a_member: "Этот пользователь не состоит в команде"`, audit `set_captain: "Назначил капитана команды"`
`en.yml`: `"Make captain"`, `"Actions"`, `"%{nickname} is now the team captain"`, `"That user is not a member of this team"`, audit `"Set the team captain"`
`uk.yml`: `"Призначити капітаном"`, `"Дії"`, `"Капітаном команди призначено %{nickname}"`, `"Цей користувач не входить до складу команди"`, audit `"Призначив капітана команди"`
`ka.yml`: `"კაპიტნად დანიშვნა"`, `"მოქმედებები"`, `"გუნდის კაპიტნად დაინიშნა %{nickname}"`, `"ეს მომხმარებელი გუნდის წევრი არ არის"`, audit `"დანიშნა გუნდის კაპიტანი"`

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/requests/admin_teams_spec.rb spec/requests/admin_audit_spec.rb spec/i18n_spec.rb`
Expected: all pass.

- [ ] **Step 8: Mutate the strict-scoping guard**

Replace `team.members.find_by(:id => params[:member_id])` with `User.find_by(:id => params[:member_id])` and re-run. The "refuses a member_id belonging to another team" example **must** fail. Restore it. If it passes, the example is not testing the scoping and needs rewriting before you continue.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/admin/teams_controller.rb app/views/admin/teams config/routes.rb config/locales spec/requests/admin_teams_spec.rb
git commit -m "Let a superadmin reassign any team's captain, audited"
```

---

### Task 4: Captain self-service handover

**Files:**
- Modify: `app/controllers/teams_controller.rb`
- Modify: `app/views/team_room/index.html.erb`
- Modify: `config/routes.rb` (`resources :teams` member block)
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: create `spec/controllers/teams/hand_over_spec.rb`

**Interfaces:**
- Consumes: `Team#set_captain!`, `Team#in_live_race?` (Task 1).
- Produces: `hand_over_team_path(team)` (POST, param `member_id`).

- [ ] **Step 1: Write the failing spec**

Create `spec/controllers/teams/hand_over_spec.rb`, matching the `perform_request` style of `spec/controllers/teams/create_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# D2 of the design: a captain may hand over voluntarily. Guarded by the
# STRICT pattern -- the team comes from the URL and the actor must be that
# team's captain -- not by SecurityFilters#ensure_team_captain, which only
# asks "is this user *a* captain" and would let the captain of team A hand
# over team B.
RSpec.describe TeamsController, "#hand_over", type: :controller do
  before :each do
    @captain = create_user
    @team = create_team(:captain => @captain)
    @successor = create_user
    @team.members << @successor
  end

  it "moves captaincy to the chosen member" do
    perform_request(:as_user => @captain, :member_id => @successor.id)

    expect(@team.reload.captain).to eq(@successor)
    expect(@successor.reload.captain?).to be true
    expect(response).to redirect_to(team_room_path)
  end

  it "leaves the outgoing captain in the team as a plain member" do
    perform_request(:as_user => @captain, :member_id => @successor.id)

    expect(@team.reload.members).to include(@captain)
    expect(@captain.reload.captain?).to be false
  end

  # D1: member-initiated changes wait for the race to end. The superadmin
  # path is deliberately NOT guarded this way -- see admin_teams_spec.
  it "refuses while the team is in a live race" do
    create_game_passing(:team => @team, :level => create_level)

    perform_request(:as_user => @captain, :member_id => @successor.id)

    expect(@team.reload.captain).to eq(@captain)
  end

  it "refuses a plain member of the same team" do
    assert_unauthorized { perform_request(:as_user => @successor, :member_id => @captain.id) }
    expect(@team.reload.captain).to eq(@captain)
  end

  # The reason for the strict guard: a captain of a DIFFERENT team must not
  # be able to hand over this one.
  it "refuses the captain of another team" do
    intruder = create_user
    create_team(:captain => intruder)

    assert_unauthorized { perform_request(:as_user => intruder, :member_id => @successor.id) }
    expect(@team.reload.captain).to eq(@captain)
  end

  it "refuses a guest" do
    assert_unauthenticated { perform_request(:member_id => @successor.id) }
    expect(@team.reload.captain).to eq(@captain)
  end

  it "refuses handing over to a user who is not a member" do
    outsider = create_user

    perform_request(:as_user => @captain, :member_id => outsider.id)

    expect(@team.reload.captain).to eq(@captain)
    expect(outsider.reload.team).to be_nil
  end

  it "refuses handing over to oneself" do
    perform_request(:as_user => @captain, :member_id => @captain.id)

    expect(@team.reload.captain).to eq(@captain)
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :hand_over, params: { id: @team.id, member_id: opts[:member_id] }
    response
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/controllers/teams/hand_over_spec.rb`
Expected: all fail — no `hand_over` route/action.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, change the bare `resources :teams` to:

```ruby
  resources :teams do
    post "hand_over", on: :member
  end
```

Note that `resources :teams` already generates `index`/`show`/`edit`/`update`/`destroy` routes with no actions behind them; they 404 via `ActionNotFound` before any filter. This change adds one member route and leaves that pre-existing shape untouched — do not "tidy" it here.

- [ ] **Step 4: Add the action**

In `app/controllers/teams_controller.rb`:

```ruby
  def hand_over
    team = Team.find(params[:id])

    # The STRICT guard: the team comes from the URL and the actor must be
    # this team's captain. SecurityFilters#ensure_team_captain only asks "is
    # this user a captain" and derives the team from current_user, so it
    # would admit the captain of any other team to this action.
    raise Authentication::Unauthorized, t("errors.must_be_captain") unless
      team.captain && team.captain.id == current_user.id

    if team.in_live_race?
      redirect_to team_room_path, :alert => t("teams.cannot_hand_over_mid_race") and return
    end

    successor = team.members.find_by(:id => params[:member_id])

    if successor.nil? || successor.id == current_user.id
      redirect_to team_room_path, :alert => t("teams.hand_over_needs_another_member") and return
    end

    team.set_captain!(successor)
    redirect_to team_room_path,
                :notice => t("teams.handed_over", :nickname => successor.nickname)
  end
```

Add `:hand_over` to the `before_action :require_authentication!` coverage — it is currently unconditional in this controller, so confirm rather than assume — and **do not** add it to `ensure_not_member_of_any_team`, which is scoped to `[:new, :create]` and would refuse every captain.

- [ ] **Step 5: Add the team-room control**

In `app/views/team_room/index.html.erb`, inside the existing `fieldset`, after the invite link:

```erb
  <% if @current_user.captain? && @team.members.count > 1 && !@team.in_live_race? %>
    <%= form_with url: hand_over_team_path(@team), method: :post do %>
      <%= select_tag :member_id,
                     options_from_collection_for_select(@team.members.reject { |m| m.id == @current_user.id }, :id, :nickname) %>
      <%= submit_tag t("team_room.index.hand_over"), :class => "btn" %>
    <% end %>
  <% end %>
```

**Frozen-suite check before you write this:** `features/games/registration-to-game.feature` has two "Не капитан" scenarios asserting that a non-captain sees neither "Подать заявку на регистрацию" nor a link "Отозвать" — on the dashboard *and* in the team room. This block renders for captains only, so it cannot collide, but re-read both scenarios and confirm your chosen label matches neither string. Also re-read `features/team-room/team-room.feature` — one scenario asserts the literal `"Noel - капитан"` and another lists member names, and this control renders member nicknames in a `select`.

- [ ] **Step 6: Add the locale keys**

All four files. `team_room.index.hand_over`, plus `teams.handed_over`, `teams.cannot_hand_over_mid_race`, `teams.hand_over_needs_another_member`:

`ru.yml`: `hand_over: "Передать капитанство"`, `handed_over: "Капитанство передано: %{nickname}"`, `cannot_hand_over_mid_race: "Нельзя передать капитанство, пока команда на дистанции"`, `hand_over_needs_another_member: "Выберите другого участника команды"`
`en.yml`: `"Hand over captaincy"`, `"Captaincy handed over to %{nickname}"`, `"Captaincy cannot be handed over while the team is racing"`, `"Choose another member of the team"`
`uk.yml`: `"Передати капітанство"`, `"Капітанство передано: %{nickname}"`, `"Не можна передати капітанство, поки команда на дистанції"`, `"Оберіть іншого учасника команди"`
`ka.yml`: `"კაპიტნობის გადაცემა"`, `"კაპიტნობა გადაეცა: %{nickname}"`, `"კაპიტნობის გადაცემა შეუძლებელია, სანამ გუნდი დისტანციაზეა"`, `"აირჩიეთ გუნდის სხვა წევრი"`

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/controllers/teams/ spec/i18n_spec.rb spec/views/team_room_spec.rb`
Expected: all pass.

- [ ] **Step 8: Mutate the strict guard**

Replace the strict check with the weak one — `raise ... unless current_user.captain?` — and re-run. The "refuses the captain of another team" example **must** fail. Restore it. This is the single most important mutation in the phase: the weak guard is already present in the codebase and is the obvious thing for a later reader to "simplify" to.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/teams_controller.rb app/views/team_room config/routes.rb config/locales spec/controllers/teams/hand_over_spec.rb
git commit -m "Let a captain hand over captaincy from the team room"
```

---

### Task 5: Full verification and PR

- [ ] **Step 1: Rebase onto current master, then re-prepare the test database**

```bash
git fetch origin master
git rebase origin/master
bin/rails db:test:prepare
```

- [ ] **Step 2: Full RSpec suite**

Run: `bundle exec rspec`
Expected: 0 failures. **Measure the baseline yourself** — do not trust a number written here. This phase adds roughly 24 examples.

- [ ] **Step 3: Full Cucumber suite**

Run: `bundle exec cucumber` (foreground, raised timeout — it takes ~170-240s).
Expected: **0 failures.** As of 2026-08-08 master stands at 232 scenarios / 2342 steps, with 2 pre-existing undefined placeholders; re-measure rather than trusting that. Confirm no feature file was touched: `git diff origin/master --stat -- features/` must print nothing.

**If a team-room or registration scenario fails, do not adjust the feature file.** The handover control is the only new thing rendering there; narrow its visibility condition or change its label instead.

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin feature/team-membership-phase-2
gh pr create --base master --title "Phase 2: captaincy reassignment and handover"
```

Write the PR body **to a file and pass `--body-file`** — a body containing backticks passed inline is executed by the shell as command substitution, which silently deletes words. (Learned in phase 1.)

The body must contain: why the surfaces exist; the two entry points and that both call `Team#set_captain!`; the deliberate D1 asymmetry (superadmin allowed mid-race, captain's own handover refused) stated explicitly so it is not "fixed" into consistency; the strict-vs-weak guard choice; the mutation checks performed with their observed failures; measured suite numbers; and the footer `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
