# Team Membership Phase 4 — Leaving a Team Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user leave their team, so `ensure_not_member_of_any_team` stops being a permanent trap.

**Architecture:** One collection action on `TeamsController` plus a control in the team room. The write is `users.team_id = nil` — except for the one case that also clears `teams.captain_id`, which is where this phase gets interesting.

**Spec:** `docs/superpowers/specs/2026-08-08-team-membership-programme-design.md` — sub-project S3, decisions D1, D3 and **D5**.

**Depends on:** phase 2 (`Team#in_live_race?`, the handover this action's refusal points at) and phase 1 (`NotificationMailer`'s captainless guard, which stops being precautionary here — see Task 1 Step 5).

**Tech Stack:** Rails 8, RSpec controller/request specs, sqlite, Cucumber.

## Global Constraints

- **Never edit `features/**/*.feature`.**
- `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` before every command.
- New i18n keys in **all four** locales, **inside the existing block** for that screen — a second key at the same level is silently discarded by YAML. `spec/i18n_spec.rb` catches it, but write it correctly.
- Hash rockets; plain fixture helpers, **no FactoryBot**.
- **No Turbo, no rails-ujs** — mutating controls are real forms.
- **Re-measure baselines.** As of this branch: **RSpec 1026 / 0 failures / 6 pending**, **Cucumber 232 / 2342 / 0 failures**.
- **Refusal signal and protected property go in SEPARATE examples** (RSpec fails fast).
- **A mutation must fail for the reason you predicted.** A malformed one goes red from a syntax error and proves nothing. A *negative* assertion passes vacuously until you have seen it fail.

## The rule this phase implements

| Who | Outcome |
|---|---|
| Plain member | Leaves. `team_id` → nil. |
| Captain **with** other members | **Refused.** Hand over first — the message says so, and the handover control sits in the same fieldset. |
| Captain who is the **only** member | **Leaves** (D5). The team is left with no members and no captain: an inert tombstone. |
| Anyone, mid-race | **Refused** (D1). |
| Someone with no team | **Refused** — nothing to leave. |

D5 is the reason phase 1's mailer guard exists. A solo captain leaving is the first thing in the app that can produce `captain_id IS NULL`, and an outstanding invitation to that team can still be accepted — which used to 500 *after* joining the invitee and deleting the invitation. Task 1 Step 5 pins that end to end.

---

### Task 1: `TeamsController#leave`

**Files:**
- Modify: `app/controllers/teams_controller.rb`, `config/routes.rb`, `config/locales/{ru,en,uk,ka}.yml`
- Test: create `spec/controllers/teams/leave_spec.rb`

**Interfaces:**
- Consumes: `Team#in_live_race?`, `User#captain?`, `Team#members`.
- Produces: `leave_teams_path` (POST, no params — the team is derived from `current_user`).

- [ ] **Step 1: Write the failing spec**

Create `spec/controllers/teams/leave_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# S3/D3 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
# Membership was one team per user, permanently: nothing anywhere set
# users.team_id back to nil, so ensure_not_member_of_any_team was a trap
# rather than a rule.
RSpec.describe TeamsController, "#leave", type: :controller do
  before :each do
    @captain = create_user
    @team = create_team(:captain => @captain)
    @member = create_user
    @team.members << @member
  end

  it "lets a plain member leave" do
    perform_request(:as_user => @member)

    expect(@member.reload.team).to be_nil
    expect(response).to redirect_to(dashboard_path)
  end

  it "leaves the team and its captain otherwise untouched" do
    perform_request(:as_user => @member)

    expect(@team.reload.captain).to eq(@captain)
    expect(@team.members).to eq([@captain])
  end

  it "refuses a captain who still has teammates" do
    perform_request(:as_user => @captain)

    expect(flash[:alert]).to eq(I18n.t("teams.hand_over_before_leaving"))
  end

  # Separate from the message above: RSpec fails fast, so a data assertion
  # after the flash check could never fail on its own.
  it "keeps a captain with teammates in their team" do
    perform_request(:as_user => @captain)

    expect(@captain.reload.team).to eq(@team)
    expect(@team.reload.captain).to eq(@captain)
  end

  # D5. There is nobody to hand to, so the role goes with them and the team
  # becomes an inert tombstone -- no members, no captain, all history intact.
  describe "a solo captain" do
    before :each do
      @solo = create_user
      @solo_team = create_team(:captain => @solo)
    end

    it "may leave" do
      perform_request(:as_user => @solo)

      expect(@solo.reload.team).to be_nil
    end

    # captain_id must be cleared too. Leaving it dangling would point
    # team.captain at someone who is no longer a member, while
    # User#captain? -- which reads through user.team -- says false: exactly
    # the divergence that makes the weak ensure_team_captain guard
    # exploitable.
    it "leaves no dangling captain behind" do
      perform_request(:as_user => @solo)

      expect(@solo_team.reload.captain).to be_nil
      expect(@solo_team.members).to be_empty
    end
  end

  it "refuses anyone while the team is in a live race" do
    create_game_passing(:team => @team, :level => create_level)

    perform_request(:as_user => @member)

    expect(@member.reload.team).to eq(@team)
  end

  it "refuses a user who is in no team" do
    stray = create_user

    perform_request(:as_user => stray)

    expect(stray.reload.team).to be_nil
    expect(response).to redirect_to(dashboard_path)
  end

  it "refuses a guest" do
    assert_unauthenticated { perform_request }
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :leave
    response
  end
end
```

- [ ] **Step 2: Run it — expect failures on the missing route**

Run: `bundle exec rspec spec/controllers/teams/leave_spec.rb`

- [ ] **Step 3: Add the route**

In `config/routes.rb`, in the existing top-level teams resource beside `hand_over`:

```ruby
    post "leave", on: :collection
```

Collection, not member: the team is derived from `current_user`, so there is no id to trust.

- [ ] **Step 4: Add the action**

In `app/controllers/teams_controller.rb`, after `hand_over`:

```ruby
  # Leaving exists so ensure_not_member_of_any_team stops being a trap: until
  # now nothing in the app set users.team_id back to nil, so a user was in
  # one team permanently.
  #
  # The team comes from current_user, never from a parameter -- there is no
  # id here to forge.
  def leave
    team = current_user.team

    if team.nil?
      redirect_to dashboard_path, :alert => t("teams.not_in_a_team") and return
    end

    # D1: member-initiated changes wait for the race to end.
    if team.in_live_race?
      redirect_to team_room_path, :alert => t("teams.cannot_leave_mid_race") and return
    end

    # A captain with teammates must hand over first, or the team is left
    # bricked -- no invitations, no registration, no way to quit a race. The
    # handover control sits in the same fieldset, so this is a signpost
    # rather than a dead end.
    solo = team.members.count == 1

    if current_user.captain? && !solo
      redirect_to team_room_path, :alert => t("teams.hand_over_before_leaving") and return
    end

    Team.transaction do
      # D5: a solo captain takes the role with them. Clearing captain_id is
      # not optional -- a dangling one would point team.captain at a
      # non-member while User#captain?, which reads through user.team, says
      # false. That divergence is what makes the weak
      # SecurityFilters#ensure_team_captain guard exploitable.
      team.update!(:captain => nil) if current_user.captain?
      current_user.update!(:team => nil)
    end

    redirect_to dashboard_path, :notice => t("teams.left_notice", :team => team.name)
  end
```

- [ ] **Step 5: Add the end-to-end proof that F3 is now load-bearing**

A solo captain leaving is the first thing in the app that produces `captain_id IS NULL`. Add to `spec/controllers/invitations/accept_spec.rb`:

```ruby
  # Phase 4 makes this reachable for real: a solo captain leaving (D5) is the
  # first thing in the app that produces a captainless team, and an
  # invitation sent before they left can still be accepted afterwards.
  # Without NotificationMailer's guard (phase 1, F3) this raised
  # NoMethodError AFTER joining the invitee and deleting the invitation.
  describe "accepting an invitation to a team whose captain has left" do
    before :each do
      @solo = create_user
      @team = create_team(:captain => @solo)
      @recepient = create_user
      @invitation = create_invitation :for => @recepient, :from => @team
      @team.update!(:captain => nil)
      @solo.update!(:team => nil)
    end

    it "joins the user without raising" do
      expect { perform_request :as_user => @recepient }.not_to raise_error
      expect(@recepient.reload.team).to eq(@team)
    end
  end
```

- [ ] **Step 6: Add locale keys** (inside the existing `teams:` block in each file)

`ru`: `left_notice: "Вы вышли из команды «%{team}»"` · `not_in_a_team: "Вы не состоите в команде"` · `cannot_leave_mid_race: "Нельзя выйти из команды, пока она на дистанции"` · `hand_over_before_leaving: "Сначала передайте капитанство другому участнику"`
`en`: `"You have left “%{team}”"` · `"You are not in a team"` · `"You cannot leave while the team is racing"` · `"Hand captaincy over to another member first"`
`uk`: `"Ви вийшли з команди «%{team}»"` · `"Ви не входите до складу команди"` · `"Не можна вийти з команди, поки вона на дистанції"` · `"Спочатку передайте капітанство іншому учаснику"`
`ka`: `"თქვენ დატოვეთ გუნდი «%{team}»"` · `"თქვენ არ ხართ გუნდის წევრი"` · `"გუნდის დატოვება შეუძლებელია, სანამ ის დისტანციაზეა"` · `"ჯერ გადააბარეთ კაპიტნობა სხვა წევრს"`

- [ ] **Step 7: Run the specs**

`bundle exec rspec spec/controllers/teams/ spec/controllers/invitations/ spec/i18n_spec.rb`

- [ ] **Step 8: Mutate each guard**

1. Delete the mid-race guard → "refuses anyone while the team is in a live race" fails.
2. Delete the `current_user.captain? && !solo` guard → **both** captain examples fail.
3. Change `solo = team.members.count == 1` to `solo = true` → the captain-with-teammates examples fail.
4. Delete `team.update!(:captain => nil) if current_user.captain?` → "leaves no dangling captain behind" fails. **Check it fails on the captain, not the members.**
5. With mutation 4 in place, the invitation example from Step 5 should also start failing — confirming F3 and D5 are genuinely coupled.

- [ ] **Step 9: Commit**

---

### Task 2: The leave control in the team room

**Files:** `app/views/team_room/index.html.erb`, `config/locales/*`, extend `spec/views/team_room_spec.rb`.

- [ ] **Step 1: Write the failing view specs** — read `spec/views/team_room_spec.rb` first and match its setup style. Assert: a plain member sees a POSTing form to `leave_teams_path`; a captain with teammates does **not**; a solo captain does; nobody does mid-race.

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Add the control**, after the handover block inside the same fieldset:

```erb
  <%# Hidden exactly where the action refuses, so it is never a promise that
      cannot be kept. A captain with teammates sees the handover control
      above instead -- hand over, and this appears. %>
  <% unless @team.in_live_race? %>
    <% if !@current_user.captain? || @team.members.count == 1 %>
      <%= button_to t("team_room.index.leave"), leave_teams_path, :method => :post, :class => "btn" %>
    <% end %>
  <% end %>
```

`button_to`, not `form_with`: there is nothing to select.

- [ ] **Step 4: Add `team_room.index.leave`** in all four locales — `ru`: `"Покинуть команду"` · `en`: `"Leave the team"` · `uk`: `"Покинути команду"` · `ka`: `"გუნდის დატოვება"`.

- [ ] **Step 5: Run the specs.**

- [ ] **Step 6: Mutate** — render the control unconditionally and confirm the captain-with-teammates example fails; swap `button_to` for `link_to` and confirm the form-shape assertion fails. Restore.

- [ ] **Step 7: Commit.**

---

### Task 3: Verification and PR

- [ ] Rebase onto master, `bin/rails db:test:prepare`.
- [ ] `bundle exec rspec` — 0 failures; roughly +14 examples.
- [ ] `bundle exec cucumber` — 0 failures, and `git diff origin/master --stat -- features/` prints nothing. **Watch `create-team.feature`**: it asserts a current member is refused at `/teams/new`. Leaving does not change that — those scenarios never leave — but it is the closest frozen scenario to this change.
- [ ] Update `docs/superpowers/queue.md`, push, and open the PR with `--body-file`.
