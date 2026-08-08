# Team Membership Phase 1 — Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make captaincy safe to change — one atomic operation, no theft, no captainless-team crash — without adding any user-facing surface yet.

**Architecture:** Three model/mailer changes plus one missing characterisation spec. `Team#set_captain!` becomes the single chokepoint through which captaincy ever changes; a new validation makes the `adopt_captain` theft path unreachable; `NotificationMailer` stops dereferencing a nil captain. No controllers, routes, views or user-facing strings — those arrive in phase 2.

**Spec:** `docs/superpowers/specs/2026-08-08-team-membership-programme-design.md` (foundations F1–F3; F4 is deferred to phase 6).

**Tech Stack:** Rails 8, RSpec, sqlite test DB, Cucumber acceptance suite.

## Global Constraints

- **Never edit `features/**/*.feature`.** Step definitions are fair game. Assume no owner authorisation is granted.
- Run every command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` — Ruby is not on `PATH` in non-login shells.
- New i18n keys go in **all four** of `config/locales/{ru,en,uk,ka}.yml`; `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity.
- Hash rockets (`:key => value`) are the house style in models and specs.
- Fixtures are plain helpers in `spec/spec_helpers/fixtures_helper.rb` — **no FactoryBot**.
- `spec/rails_helper.rb` enables the legacy `should` syntax; new specs prefer `expect`.
- Cucumber takes ~170s and exceeds a subagent's 120s Bash timeout. The coordinating session runs it, or run it in the foreground with a raised timeout.
- **When you write a guard-style assertion, break the code and watch it fail before trusting it.** Four assertions in recent security work could not fail; all were caught by mutation, none by inspection.

---

### Task 1: Characterise team creation before anything changes it

`spec/controllers/teams/create_spec.rb` does not exist — the only code in the app that sets a captain has no controller spec. Task 4 changes the callback that team creation depends on, so this spec must exist **first**, to pin the behaviour that narrowing has to preserve.

**Files:**
- Create: `spec/controllers/teams/create_spec.rb`
- Read for reference: `spec/controllers/teams/new_spec.rb` (helper shape), `app/controllers/teams_controller.rb`

**Interfaces:**
- Consumes: `create_user`, `create_team` (`spec/spec_helpers/fixtures_helper.rb`); `assert_unauthenticated` (spec support).
- Produces: nothing downstream. Pure characterisation.

- [ ] **Step 1: Write the spec**

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The only code in the app that sets a captain had no controller spec.
# Written before Phase 1 touches Team#adopt_captain, because team creation
# DEPENDS on that callback: TeamsController#create assigns a captain who has
# no team_id yet, and the after_save is what makes the creator a member.
RSpec.describe TeamsController, "#create", type: :controller do
  describe "a fresh user creates a team" do
    before :each do
      @user = create_user
      perform_request(:as_user => @user, :name => "Мухоморы")
    end

    it "creates the team and redirects to the dashboard" do
      expect(Team.find_by(:name => "Мухоморы")).not_to be_nil
      expect(response).to redirect_to(dashboard_path)
    end

    # This is the behaviour Task 4 must preserve.
    it "makes the creator both the captain and a member of the new team" do
      team = Team.find_by(:name => "Мухоморы")
      expect(team.captain).to eq(@user)
      expect(team.members).to include(@user)
      expect(@user.reload.team).to eq(team)
      expect(@user.captain?).to be true
    end
  end

  describe "a guest attempts to create a team" do
    it "raises Unauthenticated exception and creates nothing" do
      expect do
        assert_unauthenticated { perform_request(:name => "Мухоморы") }
      end.not_to change(Team, :count)
    end
  end

  describe "a member of some team attempts to create another" do
    before :each do
      @user = create_user
      @team = create_team(:captain => @user)
    end

    it "refuses and creates nothing" do
      expect { perform_request(:as_user => @user, :name => "Вторая") }
        .not_to change(Team, :count)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :create, params: { team: { name: opts[:name] } }
    response
  end
end
```

- [ ] **Step 2: Run it — it must pass immediately**

Run: `bundle exec rspec spec/controllers/teams/create_spec.rb`
Expected: **4 examples, 0 failures.** This is characterisation of existing behaviour, so passing on the first run is correct here — the usual "watch it fail" rule does not apply. If anything fails, stop: the app does not behave as the design assumes, and the design needs revisiting before you continue.

- [ ] **Step 3: Commit**

```bash
git add spec/controllers/teams/create_spec.rb
git commit -m "Characterise team creation before Phase 1 touches its callback"
```

---

### Task 2: F3 — stop the captainless-team crash in the mailer

**Files:**
- Modify: `app/mailers/notification_mailer.rb` (`reject_notification` ~`:48`, `accept_notification` ~`:56`)
- Test: `spec/mailers/notification_mailer_spec.rb` (extend the existing `#accept_notification` / `#reject_notification` describes, ~`:97` and `:112`)
- Test: `spec/controllers/invitations/accept_spec.rb` (add the integration case)

**Interfaces:**
- Consumes: nothing new.
- Produces: `accept_notification` / `reject_notification` become no-ops (Rails `NullMail`) when `team.captain` is nil, instead of raising `NoMethodError`.

- [ ] **Step 1: Write the failing mailer tests**

Add inside the existing `describe "#accept_notification"` block in `spec/mailers/notification_mailer_spec.rb`:

```ruby
    # A captainless team is a valid model state (captain_id is nullable, and
    # Phase 1 of the team-membership programme makes it reachable). This
    # dereferenced team.captain.locale and .email, and InvitationsController
    # #accept calls it AFTER joining the invitee and deleting the invitation
    # -- so the crash left a partial commit plus an error page.
    it "delivers nothing, rather than raising, when the team has no captain" do
      team = Team.create!(:name => "Безголовые")
      alisa = User.create!(:nickname => "Alisa3", :email => "alisa3@diesel.kg",
                           :password => "1234", :password_confirmation => "1234")

      expect do
        described_class.accept_notification(alisa, team).deliver_now
      end.not_to change { ActionMailer::Base.deliveries.count }
    end
```

And the mirror inside `describe "#reject_notification"`:

```ruby
    it "delivers nothing, rather than raising, when the team has no captain" do
      team = Team.create!(:name => "Безголовые-2")
      alisa = User.create!(:nickname => "Alisa4", :email => "alisa4@diesel.kg",
                           :password => "1234", :password_confirmation => "1234")

      expect do
        described_class.reject_notification(alisa, team).deliver_now
      end.not_to change { ActionMailer::Base.deliveries.count }
    end
```

- [ ] **Step 2: Run them to verify they fail for the right reason**

Run: `bundle exec rspec spec/mailers/notification_mailer_spec.rb`
Expected: **2 failures, both `NoMethodError: undefined method 'locale' for nil`** — raised out of the `expect { }` block. If you see a different error, or a plain "count changed" failure, stop and read it: the reason matters more than the redness.

- [ ] **Step 3: Implement the guard**

In `app/mailers/notification_mailer.rb`, in **both** methods, insert the guard after the `@user` assignment:

```ruby
  def reject_notification(user, team)
    @user = user
    # A captainless team has nobody to notify. captain_id is nullable and
    # Team declares `belongs_to :captain, optional: true`, so this is a
    # valid state, not a corrupt one -- and returning before `mail` yields
    # ActionMailer's NullMail, which makes the caller's deliver_now a no-op
    # without the caller needing to know. Deliberately NOT fixed by
    # reordering InvitationsController#accept: that ordering is itself
    # deliberate and commented; the defect is the unguarded dereference.
    return if team.captain.nil?

    mail_in_recipient_locale(team.captain, :reject_notification)
  end
```

```ruby
  def accept_notification(user, team)
    @user = user
    # See #reject_notification above for why this returns rather than
    # reordering the caller.
    return if team.captain.nil?

    mail_in_recipient_locale(team.captain, :accept_notification)
  end
```

- [ ] **Step 4: Run the mailer specs to verify they pass**

Run: `bundle exec rspec spec/mailers/notification_mailer_spec.rb`
Expected: all pass, 0 failures.

- [ ] **Step 5: Write the failing integration test**

The mailer unit test does not prove the *partial commit* is gone. Add to `spec/controllers/invitations/accept_spec.rb`, matching that file's existing describe/`perform_request` style (read it first — do not assume the helper's shape):

```ruby
  # The reachable form of the captainless-team crash: accept is gated on
  # being the RECIPIENT, not on the team having a captain, and the mailer
  # fires after the join and after the invitation row is deleted. Before the
  # guard this raised NoMethodError with the user already joined and the
  # invitation already gone.
  describe "accepting an invitation to a team whose captain is gone" do
    before :each do
      @user = create_user
      @team = create_team
      @invitation = Invitation.create!(:to_team => @team,
                                       :recepient_nickname => @user.nickname)
    end

    it "joins the user and completes without raising" do
      expect { perform_request(:as_user => @user) }.not_to raise_error
      expect(@user.reload.team).to eq(@team)
      expect(Invitation.find_by(:id => @invitation.id)).to be_nil
    end
  end
```

Note `create_team` with no `:captain` option produces a captainless team — check `spec/spec_helpers/fixtures_helper.rb:26-32` and confirm before relying on it.

- [ ] **Step 6: Run it, then confirm it passes with the guard in place**

Run: `bundle exec rspec spec/controllers/invitations/accept_spec.rb`
Expected: passes. Then **mutate to prove it can fail**: temporarily remove the `return if team.captain.nil?` line from `accept_notification`, re-run, confirm this example fails with `NoMethodError`, and restore the line.

- [ ] **Step 7: Commit**

```bash
git add app/mailers/notification_mailer.rb spec/mailers/notification_mailer_spec.rb spec/controllers/invitations/accept_spec.rb
git commit -m "Stop the captainless-team crash in invitation notifications"
```

---

### Task 3: F1 — `Team#set_captain!`, the single captaincy operation

**Files:**
- Modify: `app/models/team.rb`
- Test: create `spec/models/team/set_captain_spec.rb`

**Interfaces:**
- Consumes: `Team#members`, `Team#captain`.
- Produces: **`Team#set_captain!(member)`** — assigns `captain` to `member`, raises `ArgumentError` if `member` is not in `team.members`, never assigns nil. Phase 2's `Admin::TeamsController#set_captain` and the captain self-service handover both call exactly this.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/team/set_captain_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# F1 of the team-membership programme: the single operation through which
# captaincy ever changes. See
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
RSpec.describe Team, "#set_captain!" do
  it "moves captaincy to another member of the same team" do
    old_captain = create_user
    successor = create_user
    team = create_team(:captain => old_captain)
    team.members << successor

    team.set_captain!(successor)

    expect(team.reload.captain).to eq(successor)
    expect(successor.reload.captain?).to be true
    expect(old_captain.reload.captain?).to be false
  end

  # The outgoing captain stays a member -- there is no way to remove anyone
  # from a team, and Phase 1 deliberately does not add one.
  it "leaves the outgoing captain in the team" do
    old_captain = create_user
    successor = create_user
    team = create_team(:captain => old_captain)
    team.members << successor

    team.set_captain!(successor)

    expect(team.reload.members).to include(old_captain)
    expect(old_captain.reload.team).to eq(team)
  end

  # The landmine this operation exists to disarm: Team#adopt_captain does
  # `members << captain` with no validation, so handing captaincy to an
  # outsider would silently overwrite that user's team_id and steal them out
  # of their own team.
  it "refuses a user who is not a member, and does not steal them" do
    old_captain = create_user
    outsider = create_user
    other_team = create_team(:captain => outsider)
    team = create_team(:captain => old_captain)

    expect { team.set_captain!(outsider) }.to raise_error(ArgumentError)

    expect(team.reload.captain).to eq(old_captain)
    expect(outsider.reload.team).to eq(other_team)
  end

  it "refuses a teamless user who is not a member" do
    old_captain = create_user
    stranger = create_user
    team = create_team(:captain => old_captain)

    expect { team.set_captain!(stranger) }.to raise_error(ArgumentError)

    expect(team.reload.captain).to eq(old_captain)
    expect(stranger.reload.team).to be_nil
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/models/team/set_captain_spec.rb`
Expected: **4 failures, all `NoMethodError: undefined method 'set_captain!'`.**

- [ ] **Step 3: Implement**

In `app/models/team.rb`, add as a **public** method (above the `protected` keyword):

```ruby
  # The single operation through which captaincy ever changes.
  #
  # Deliberately has no revoke counterpart: a bare revoke sets captain_id to
  # nil, which is the bricked-team state this whole programme exists to
  # remove -- such a team can never invite, never register for a game and
  # never quit a race it is already in, because every one of those guards
  # asks "are you the captain".
  #
  # Membership is required rather than merely conventional:
  # features/invitations/send-invitations.feature freezes "a captain is a
  # member of their own team" by refusing a captain who invites themselves
  # as already being a member. Restricting the candidate set to members also
  # makes adopt_captain's overwrite of users.team_id a no-op here.
  #
  # ArgumentError rather than a validation error, matching the refusal style
  # of the GamePassing operator interventions, whose controller rescues it.
  def set_captain!(member)
    raise ArgumentError, "user is not a member of this team" unless members.include?(member)

    update!(:captain => member)
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/team/set_captain_spec.rb`
Expected: 4 examples, 0 failures.

- [ ] **Step 5: Mutate to prove the guard assertion can fail**

Temporarily change the guard line to `raise ArgumentError, "..." if false`, re-run, and confirm the two refusal examples fail — specifically that "refuses a user who is not a member, and does not steal them" fails on the **stolen `outsider.team`** assertion, not merely on the missing raise. Restore the line.

- [ ] **Step 6: Commit**

```bash
git add app/models/team.rb spec/models/team/set_captain_spec.rb
git commit -m "Add Team#set_captain!, the single operation that changes captaincy"
```

---

### Task 4: F2 — refuse a captain who belongs to another team

`set_captain!` closes the theft path for *our* code. This closes it at the model, for any caller — including `Team.create!(:captain => someone_elses_member)`.

A **validation**, not a narrowing of the callback: skipping the adoption would leave `captain_id` pointing at a non-member, and that divergence is exactly what makes `SecurityFilters#ensure_team_captain` exploitable (it asks "is this user *a* captain", deriving the team from `current_user.team`). Refusing the save leaves no divergent state to exploit.

**Files:**
- Modify: `app/models/team.rb`
- Modify: `config/locales/ru.yml`, `en.yml`, `uk.yml`, `ka.yml` — under `activerecord.errors.models`, add a `team:` entry beside the existing `answer:` / `game:` entries (`ru.yml` ~`:608`)
- Test: create `spec/models/team/captain_membership_spec.rb`

**Interfaces:**
- Consumes: `Team#captain`, `User#team_id`.
- Produces: `Team` is invalid when `captain.team_id` is present and differs from the team's own `id`. Teamless captains still validate — **this is load-bearing for `TeamsController#create`**, pinned by Task 1.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/team/captain_membership_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# F2 of the team-membership programme. Team#adopt_captain does
# `members << captain` on every after_save with no validation, and `members`
# is has_many :users -- so assigning an outsider as captain silently
# overwrote their users.team_id and moved them out of their own team, with
# no error and no notification to the team they were taken from.
#
# Nothing pinned that behaviour: spec/models/team/filters_spec.rb's
# "external" captain is built with a bare create_user and is therefore
# TEAMLESS, so it exercises the adopt path, never the steal path.
RSpec.describe Team, "captain membership" do
  it "refuses a captain who already belongs to another team" do
    victim = create_user
    other_team = create_team(:captain => victim)
    team = create_team(:captain => create_user)

    team.captain = victim

    expect(team.save).to be false
    expect(victim.reload.team).to eq(other_team)
  end

  # Load-bearing for TeamsController#create, where the creator has no
  # team_id yet and adopt_captain is what makes them a member.
  it "accepts a teamless captain and adopts them into the team" do
    founder = create_user
    team = Team.new(:name => "Новая команда", :captain => founder)

    expect(team.save).to be true
    expect(team.members).to include(founder)
    expect(founder.reload.team).to eq(team)
  end

  it "still accepts re-saving a team whose captain is already its member" do
    captain = create_user
    team = create_team(:captain => captain)

    team.name = "Переименованная"

    expect(team.save).to be true
    expect(team.reload.captain).to eq(captain)
  end
end
```

- [ ] **Step 2: Run it to verify the first example fails**

Run: `bundle exec rspec spec/models/team/captain_membership_spec.rb`
Expected: **1 failure** — "refuses a captain who already belongs to another team", because `team.save` returns `true` and the victim has been moved. The other two examples should already pass.

- [ ] **Step 3: Implement the validation**

In `app/models/team.rb`, add the declaration below the existing `validates :name` line:

```ruby
  validate :captain_is_not_another_teams_member
```

and the check itself, in the `protected` section beside `adopt_captain`:

```ruby
  # adopt_captain (below) overwrites users.team_id, so without this a team
  # could take a captain straight out of somebody else's team. Refusing the
  # save is deliberately preferred to skipping the adoption: skipping would
  # leave captain_id pointing at a non-member, and User#captain? reads
  # through user.team rather than teams.captain_id, so the two would
  # disagree -- which is precisely the divergence that makes the weak
  # SecurityFilters#ensure_team_captain guard exploitable.
  #
  # A teamless captain is fine and must stay fine: TeamsController#create
  # assigns a captain who has no team yet, and adoption is what makes the
  # creator a member.
  def captain_is_not_another_teams_member
    return if captain.nil?
    return if captain.team_id.nil? || captain.team_id == id

    errors.add(:captain, :belongs_to_another_team)
  end
```

- [ ] **Step 4: Add the locale keys**

In each of the four locale files, under `activerecord: errors: models:`, add a `team` entry (alphabetically it sits after `game`; match the surrounding indentation exactly):

`config/locales/ru.yml`:
```yaml
        team:
          attributes:
            captain:
              belongs_to_another_team: "уже состоит в другой команде"
```

`config/locales/en.yml`:
```yaml
        team:
          attributes:
            captain:
              belongs_to_another_team: "already belongs to another team"
```

`config/locales/uk.yml`:
```yaml
        team:
          attributes:
            captain:
              belongs_to_another_team: "вже перебуває в іншій команді"
```

`config/locales/ka.yml`:
```yaml
        team:
          attributes:
            captain:
              belongs_to_another_team: "უკვე სხვა გუნდის წევრია"
```

- [ ] **Step 5: Run the spec and the i18n parity spec**

Run: `bundle exec rspec spec/models/team/captain_membership_spec.rb spec/i18n_spec.rb spec/controllers/teams/create_spec.rb spec/models/team/filters_spec.rb`
Expected: all pass. `filters_spec` and `create_spec` passing is the point — they prove the narrowing preserved the adopt path.

- [ ] **Step 6: Commit**

```bash
git add app/models/team.rb config/locales spec/models/team/captain_membership_spec.rb
git commit -m "Refuse a captain who already belongs to another team"
```

---

### Task 5: Full verification and PR

**Files:** none new.

- [ ] **Step 1: Full RSpec suite**

Run: `bundle exec rspec`
Expected: 0 failures. Baseline on master is **889 examples / 6 pending**; this phase adds 13 examples → **902**. Any *other* example that turns red is a real find, not noise — most likely a fixture somewhere assigning a captain who already has a team. Investigate rather than adjusting the new validation.

- [ ] **Step 2: Full Cucumber suite**

Run: `bundle exec cucumber` (foreground, raised timeout — it takes ~170s).
Expected: **234 scenarios, 0 failures** (232 passed + 2 pre-existing undefined placeholders). Confirm no feature file was touched: `git diff origin/master --stat -- features/` must print nothing.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feature/team-membership-phase-1
gh pr create --base master --title "Phase 1: foundations for changing a team's captain"
```

The PR body must contain, in this order:

1. **Why** — a captain who stops logging in bricks their team permanently; you cannot leave, be removed, or delete a team, and every captaincy guard asks "are you the captain", which is useless when the captain is the problem. Link the design doc and PR #38's brief.
2. **What** — the three foundations, each with its one-line reason: `Team#set_captain!` as the single chokepoint (no revoke, because a bare revoke *is* the bricked state); the validation refusing a captain who belongs to another team (refuse rather than skip adoption, because skipping leaves `captain_id` diverged from membership and that divergence is what makes the weak guard exploitable); the mailer guard (a captainless team has nobody to notify, and the crash left a partial commit).
3. **Explicitly: no user-facing surface is added.** No controller, route, view or UI string. Phase 2 adds those.
4. **Verification** — the RSpec and Cucumber numbers from Steps 1–2, and the three mutation checks performed (Task 2 Step 6, Task 3 Step 5) stated as done with their observed failures.
5. Footer: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`
