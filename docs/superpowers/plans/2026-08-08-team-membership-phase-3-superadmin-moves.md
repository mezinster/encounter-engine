# Team Membership Phase 3 — Superadmin Moves Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin move a user from one team to another without that user's consent, audited, and refused in the cases where it would do damage.

**Architecture:** One member action on the existing `Admin::UsersController`, which already carries the grant/revoke pattern, plus a control on the user detail page. No new model methods: the move is a single `users.team_id` write. All the difficulty is in the refusals.

**Spec:** `docs/superpowers/specs/2026-08-08-team-membership-programme-design.md` — sub-project S2, decision D1.

**Depends on:** phase 2 (#49), which provides `Team#in_live_race?` and the captaincy reassignment this action's refusal points operators at.

**Tech Stack:** Rails 8, RSpec request specs, sqlite test DB, Cucumber acceptance suite.

## Global Constraints

- **Never edit `features/**/*.feature`.** Step definitions are fair game.
- Run every command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- New i18n keys go in **all four** locale files. Add them **inside the existing block for that model or screen** — a second `users:` or `teams:` key at the same level is silently discarded by YAML and the message vanishes. `spec/i18n_spec.rb` now catches that, but the fix is to write it correctly, not to rely on the guard.
- Hash rockets are the house style. Fixtures are plain helpers — **no FactoryBot**.
- **No Turbo, no rails-ujs.** A `select` cannot ride `button_to`; use `form_with`. A `link_to ..., method: :post` silently issues a GET.
- **Re-measure both baselines on your own branch.** Master moved four times during phases 1–2. As of this branch's creation: **RSpec 1014 / 0 failures / 6 pending**, **Cucumber 232 scenarios / 2342 steps / 0 failures**.
- **The refusal signal and the property it protects go in SEPARATE examples.** RSpec fails fast, so an assertion sitting after `assert_unauthorized` or `raise_error` in the same example can never fail on its own. Both previous phases found one of their own security assertions decorative this way.

---

### Task 1: `Admin::UsersController#move`

**Files:**
- Modify: `app/controllers/admin/users_controller.rb`
- Modify: `config/routes.rb` (the admin `resources :users` member block, beside `grant`/`revoke`)
- Modify: `config/locales/{ru,en,uk,ka}.yml` — flash messages inside the **existing** `admin.users` block, and the audit label inside the **existing** `admin.audit.index.action` block
- Test: create `spec/requests/admin_user_moves_spec.rb`

**Interfaces:**
- Consumes: `Team#in_live_race?` (phase 2), `User#captain?`, `record_admin_action`.
- Produces: `move_admin_user_path(user)` (POST, param `team_id`).

**The four refusals, and why each exists:**

1. **The user is a captain.** Moving them would leave their team captainless — the bricked state the whole programme exists to remove — and `users.team_id` and `teams.captain_id` would disagree, which is the divergence that makes the weak `ensure_team_captain` guard exploitable. The message names captaincy reassignment as the remedy, or an operator meets "cannot move: this user is a captain" with no hint at the fix.
2. **The destination team is mid-race.** Adding a player to a run already under way hands them a level their teammates solved.
3. **The source team is mid-race.** Removing a player mid-run changes a racing team's composition without their captain's knowledge. Consent-free moves wait for the race to end — D1.
4. **The destination is the team they are already in**, or does not exist. Nothing to do; refuse rather than write a no-op audit entry.

A **teamless** user is deliberately movable: there is no source team to disturb, and this is how an operator places someone who has no team.

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/admin_user_moves_spec.rb`:

```ruby
require "rails_helper"

# S2 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md:
# a superadmin moves a user between teams without their consent. The move
# itself is one column write; every refusal below is the actual feature.
describe "moving a user between teams", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Verified: config/routes.rb maps GET /login to sessions#new and PUT /login
  # to sessions#update. create_user sets the password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A plain member: create_team makes its captain a member via adopt_captain,
  # so a team built with a separate captain has exactly one movable member.
  def team_with_member
    captain = create_user
    team = create_team(:captain => captain)
    member = create_user
    team.members << member
    [team, member]
  end

  it "moves a plain member to another team and records an audit entry" do
    source, member = team_with_member
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(destination)
    expect(response).to redirect_to(admin_user_path(member))
    action = AdminAction.order(:id).last
    expect(action.action).to eq("move_user")
    expect(action.target_id).to eq(member.id)
  end

  it "places a teamless user into a team" do
    stray = create_user
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(stray), :params => { :team_id => destination.id }

    expect(stray.reload.team).to eq(destination)
  end

  # Refusal 1. The remedy is captaincy reassignment, which the message names.
  it "refuses to move a captain, leaving both team and captaincy intact" do
    captain = create_user
    source = create_team(:captain => captain)
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(captain), :params => { :team_id => destination.id }

    expect(captain.reload.team).to eq(source)
    expect(source.reload.captain).to eq(captain)
    expect(flash[:alert]).to eq(I18n.t("admin.users.cannot_move_captain"))
  end

  # Refusal 2.
  it "refuses to move anyone into a team that is mid-race" do
    source, member = team_with_member
    destination = create_team(:captain => create_user)
    create_game_passing(:team => destination, :level => create_level)
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
  end

  # Refusal 3.
  it "refuses to move anyone out of a team that is mid-race" do
    source, member = team_with_member
    create_game_passing(:team => source, :level => create_level)
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
  end

  # Refusal 4.
  it "refuses a move into the team the user is already in" do
    source, member = team_with_member
    sign_in(superadmin)

    expect do
      post move_admin_user_path(member), :params => { :team_id => source.id }
    end.not_to change(AdminAction, :count)

    expect(member.reload.team).to eq(source)
  end

  it "refuses an unknown destination team" do
    source, member = team_with_member
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => 0 }

    expect(member.reload.team).to eq(source)
  end

  it "refuses an ordinary signed-in user" do
    source, member = team_with_member
    destination = create_team(:captain => create_user)
    sign_in(create_user)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an anonymous visitor" do
    source, member = team_with_member
    destination = create_team(:captain => create_user)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
    expect(response).to redirect_to(login_path)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/admin_user_moves_spec.rb`
Expected: every example fails on `undefined ... move_admin_user_path`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the admin namespace's users resource, beside `grant` and `revoke`:

```ruby
      post "move", on: :member
```

- [ ] **Step 4: Add the action**

In `app/controllers/admin/users_controller.rb`, after `revoke`, following that method's "refuse before anything changes" shape so no audit entry is written for a move that did not happen:

```ruby
  # Consent-free, so every refusal below matters more than the move itself.
  # See docs/superpowers/specs/2026-08-08-team-membership-programme-design.md,
  # S2.
  def move
    user = User.find(params[:id])
    destination = Team.find_by(:id => params[:team_id])
    source = user.team

    # Moving a captain would leave their team captainless -- the bricked state
    # this programme exists to remove -- and would put users.team_id and
    # teams.captain_id in disagreement, which is the divergence that makes the
    # weak SecurityFilters#ensure_team_captain guard exploitable. The message
    # names the remedy, or an operator meets a refusal with no hint at the fix.
    if user.captain?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_move_captain") and return
    end

    if destination.nil? || destination == source
      redirect_to admin_user_path(user), :alert => t("admin.users.move_needs_another_team") and return
    end

    # D1: consent-free changes wait for the race to end. Both ends matter --
    # joining a run already under way hands the newcomer levels their
    # teammates solved, and leaving one changes a racing team's composition
    # without its captain knowing.
    if destination.in_live_race? || source&.in_live_race?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_move_mid_race") and return
    end

    user.update!(:team => destination)
    record_admin_action("move_user", user, "#{source&.name} -> #{destination.name}")
    redirect_to admin_user_path(user),
                :notice => t("admin.users.moved_notice", :team => destination.name)
  end
```

- [ ] **Step 5: Add the locale keys**

**Inside the existing `admin.users` block** in each file, beside `cannot_revoke_last`:

`ru.yml`
```yaml
      moved_notice: "Игрок переведён в команду «%{team}»"
      cannot_move_captain: "Нельзя перевести капитана. Сначала назначьте другого капитана его команде."
      cannot_move_mid_race: "Нельзя переводить игроков, пока команда на дистанции"
      move_needs_another_team: "Выберите другую команду"
```

`en.yml`
```yaml
      moved_notice: "The player has been moved to “%{team}”"
      cannot_move_captain: "A captain cannot be moved. Give their team another captain first."
      cannot_move_mid_race: "Players cannot be moved while the team is racing"
      move_needs_another_team: "Choose a different team"
```

`uk.yml`
```yaml
      moved_notice: "Гравця переведено до команди «%{team}»"
      cannot_move_captain: "Не можна перевести капітана. Спочатку призначте його команді іншого капітана."
      cannot_move_mid_race: "Не можна переводити гравців, поки команда на дистанції"
      move_needs_another_team: "Оберіть іншу команду"
```

`ka.yml`
```yaml
      moved_notice: "მოთამაშე გადაყვანილია გუნდში «%{team}»"
      cannot_move_captain: "კაპიტნის გადაყვანა შეუძლებელია. ჯერ დანიშნეთ მის გუნდს სხვა კაპიტანი."
      cannot_move_mid_race: "მოთამაშეების გადაყვანა შეუძლებელია, სანამ გუნდი დისტანციაზეა"
      move_needs_another_team: "აირჩიეთ სხვა გუნდი"
```

**Inside the existing `admin.audit.index.action` block**, beside `set_captain`:

`ru`: `move_user: "Перевёл игрока в другую команду"` · `en`: `move_user: "Moved a player to another team"` · `uk`: `move_user: "Перевів гравця до іншої команди"` · `ka`: `move_user: "გადაიყვანა მოთამაშე სხვა გუნდში"`

- [ ] **Step 6: Run the specs**

Run: `bundle exec rspec spec/requests/admin_user_moves_spec.rb spec/requests/admin_audit_spec.rb spec/i18n_spec.rb`
Expected: all pass.

- [ ] **Step 7: Mutate each refusal in turn**

Each must be observed failing, then restored:

1. Delete the `user.captain?` guard → "refuses to move a captain" must fail. **Check what it fails on**: if it fails only on the flash, the captaincy-intact assertion never ran, and the data property needs its own example.
2. Change `destination.in_live_race? || source&.in_live_race?` to `destination.in_live_race?` → "out of a team that is mid-race" must fail.
3. Change it to `source&.in_live_race?` → "into a team that is mid-race" must fail.
4. Delete the `destination == source` clause → "refuses a move into the team the user is already in" must fail on the `AdminAction` count.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/admin/users_controller.rb config/routes.rb config/locales spec/requests/admin_user_moves_spec.rb
git commit -m "Let a superadmin move a user between teams, audited and guarded"
```

---

### Task 2: The control on the user detail page

**Files:**
- Modify: `app/views/admin/users/show.html.erb`
- Modify: `config/locales/{ru,en,uk,ka}.yml` (label inside the existing `admin.users.show` block)
- Test: extend `spec/requests/admin_user_moves_spec.rb`

**Interfaces:**
- Consumes: `move_admin_user_path` from Task 1.
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

```ruby
  describe "the control on the user page" do
    it "offers a move form for a plain member" do
      _source, member = team_with_member
      create_team(:captain => create_user)
      sign_in(superadmin)

      get admin_user_path(member)

      expect(response.body).to match(
        %r{<form[^>]*method="post"[^>]*action="#{Regexp.escape(move_admin_user_path(member))}"}
      )
    end

    # A captain cannot be moved, so offering the control would be a promise
    # the action refuses to keep.
    it "does not offer it for a captain" do
      captain = create_user
      create_team(:captain => captain)
      create_team(:captain => create_user)
      sign_in(superadmin)

      get admin_user_path(captain)

      expect(response.body).not_to include(move_admin_user_path(captain))
    end
  end
```

Note the form assertion pins **a POSTing form**, not merely the path — a `link_to ..., method: :post` would satisfy a path check and then silently GET.

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/admin_user_moves_spec.rb`
Expected: the two new examples fail; the Task 1 examples still pass.

- [ ] **Step 3: Add the control**

In `app/views/admin/users/show.html.erb`, inside the existing `game-control` div, after the grant/revoke button:

```erb
  <%# A captain cannot be moved (the action refuses it), so the control is not
      offered for one -- the remedy is captaincy reassignment on the admin
      teams screen. A form rather than a link: no Turbo, no rails-ujs, and a
      select cannot ride button_to. %>
  <% unless @user.captain? %>
    <% destinations = Team.where.not(:id => @user.team_id).order(:name) %>
    <% if destinations.any? %>
      <%= form_with url: move_admin_user_path(@user), method: :post do %>
        <%= select_tag :team_id, options_from_collection_for_select(destinations, :id, :name) %>
        <%= submit_tag t("admin.users.show.move"), :class => "btn" %>
      <% end %>
    <% end %>
  <% end %>
```

- [ ] **Step 4: Add the label**

Inside the existing `admin.users.show` block: `ru`: `move: "Перевести в команду"` · `en`: `move: "Move to team"` · `uk`: `move: "Перевести до команди"` · `ka`: `move: "გუნდში გადაყვანა"`

- [ ] **Step 5: Run the specs**

Run: `bundle exec rspec spec/requests/admin_user_moves_spec.rb spec/i18n_spec.rb`
Expected: all pass.

- [ ] **Step 6: Mutate**

Change `unless @user.captain?` to `if true` and re-run: "does not offer it for a captain" must fail. Restore.

- [ ] **Step 7: Commit**

```bash
git add app/views/admin/users/show.html.erb config/locales spec/requests/admin_user_moves_spec.rb
git commit -m "Offer the move control on the admin user page"
```

---

### Task 3: Verification and PR

- [ ] **Step 1: Rebase and re-prepare**

```bash
git fetch origin master
git rebase origin/master
bin/rails db:test:prepare
```

- [ ] **Step 2: Full RSpec**

Run: `bundle exec rspec` — 0 failures. This phase adds roughly 12 examples to the measured baseline.

- [ ] **Step 3: Full Cucumber**

Run: `bundle exec cucumber` (foreground, raised timeout). 0 failures, and `git diff origin/master --stat -- features/` must print nothing. Nothing here renders outside the admin console, which has no acceptance coverage, so a failure would mean something unexpected — investigate rather than adjust.

- [ ] **Step 4: Update the queue and open the PR**

Mark phase 3 built in `docs/superpowers/queue.md`, then:

```bash
git push -u origin feature/team-membership-phase-3
gh pr create --base master --title "Phase 3: superadmin moves a user between teams"
```

Pass the body via `--body-file` — backticks in an inline body are executed by the shell and silently delete words.
