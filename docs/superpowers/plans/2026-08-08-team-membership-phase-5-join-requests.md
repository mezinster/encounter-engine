# Team Membership Phase 5 — Join Requests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user apply to join a team, and let that team's captain approve or refuse — the user→captain direction the existing `Invitation` model cannot express.

**Architecture:** A new `TeamJoinRequest(user, team, status)` mirroring `GameEntry`'s status shape, a controller carrying create/accept/reject, a teams index for discovery (the `resources :teams` index route already exists and currently 404s), and a pending-requests block in the team room. Accepting detaches the applicant from their current team, which is why this phase depends on phase 4.

**Spec:** `docs/superpowers/specs/2026-08-08-team-membership-programme-design.md` — sub-project S4, decisions D1 and D3.

**Depends on:** phase 4 (#51) for leaving, phase 2 for `Team#in_live_race?` and the handover a captain needs before applying elsewhere.

**Tech Stack:** Rails 8, RSpec, sqlite, Cucumber.

## Global Constraints

- **Never edit `features/**/*.feature`.**
- `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` before every command.
- i18n keys in **all four** locales, **inside the existing block** for that screen.
- Hash rockets; plain fixture helpers, **no FactoryBot**.
- **No Turbo, no rails-ujs** — mutating controls are real forms.
- **Re-measure baselines.** As of this branch: **RSpec 1040 / 0 failures / 6 pending**, **Cucumber 232 / 2342 / 0 failures**.
- **Refusal signal and protected property in SEPARATE examples** (RSpec fails fast).
- **A mutation must fail for the predicted reason.** Negative assertions pass vacuously until seen to fail.
- **A test that constructs an end state cannot prove the system reaches it** — when the claim is "A makes B reachable", travel from A to B.

## Why not reuse `Invitation`

`Invitation` validates `recepient_is_not_member_of_any_team` (`app/models/invitation.rb:22-24`), and **three frozen scenarios pin that refusal** in `features/invitations/send-invitations.feature` — a member of another team, a member of the same team, and oneself, all rejected with «Пользователь уже является членом одной из команд». Reusing it for transfer would mean relaxing exactly the rule those scenarios freeze.

It also points the wrong way: `Invitation` is captain → user, keyed by `recepient_nickname`. A join request is user → captain.

## Frozen-suite exposure

Checked: no scenario visits a teams *list* page — `create-team.feature` only visits `/teams/new`. The new index is therefore free of frozen assertions. The **team room** is not: `registration-to-game.feature`'s two "Не капитан" scenarios assert a non-captain sees neither "Подать заявку на регистрацию" nor a link "Отозвать" there.

**The pending-requests block is captain-only, and its strings must avoid both of those.** «Подать заявку на регистрацию» is the *game* registration string — do not reuse the word combination for join requests. Use «Заявки на вступление» for the block and «Принять» / «Отклонить» for the buttons.

---

### Task 1: Migration and `TeamJoinRequest`

**Files:** `db/migrate/<timestamp>_create_team_join_requests.rb`, `db/schema.rb`, `app/models/team_join_request.rb`, `spec/models/team_join_request_spec.rb`.

Columns: `user_id` (null: false), `team_id` (null: false), `status` (null: false, default `"new"`), timestamps. Index on `[user_id, team_id]`, plus a **partial unique index on the live status** — `where: "status = 'new'"` — so one pending request per (user, team). That mirrors the scoped index PR #42 added to `game_entries`, and for the same reason: a double-clicked button must not create two live rows, while historical rejected rows stay legal.

Model: `belongs_to :user`, `belongs_to :team`, `validates :user`/`:team` presence, scopes `pending`/`of_user`/`to_team`, and `accept!`/`reject!` mirroring `GameEntry`.

- [ ] Write `spec/models/team_join_request_spec.rb` first: a request is created `"new"`; `accept!`/`reject!` move the status; two pending rows for the same pair are refused by the index; a rejected row does not block a fresh request.
- [ ] Run it — fails on the missing constant.
- [ ] Write the migration and model. `bin/rails db:migrate` then `bin/rails db:test:prepare`.
- [ ] Run the spec; then mutate the partial index to a blanket unique index and confirm "a rejected row does not block a fresh request" fails.
- [ ] Commit.

---

### Task 2: Applying — `TeamJoinRequestsController#create`

**Route:** `post "/teams/:team_id/join_requests", to: "team_join_requests#create", as: :team_join_requests`.

**Refusals**, each its own example, and the data property separate from the message:

1. **A captain may not apply elsewhere.** Accepting would detach them and leave their team captainless *with members* — the bricked state. Message names handover as the remedy, same wording pattern as phase 4's leave refusal.
2. **Not to the team they are already in.**
3. **Not while their current team is mid-race** (D1).
4. **Not twice** — a pending request to the same team is refused rather than duplicated.
5. Guests refused.

A teamless user applying is the ordinary case.

- [ ] Failing request spec → route → controller → locales → run → mutate each refusal → commit.

---

### Task 3: Deciding — `accept` and `reject`

**Routes:** `post "/join_requests/:id/accept"` and `.../reject`.

**The guard is the strict one**: the request carries its own `team_id`, so the actor must be *that* team's captain. `SecurityFilters#ensure_team_captain` only asks "is this user *a* captain" and would let the captain of team A decide team B's requests — the exact hole phase 2's mutation demonstrated is real.

**Accepting:**
- refuses if either the applicant's current team or the target team is mid-race (D1);
- detaches the applicant from their current team and attaches them to the target — one transaction;
- **auto-rejects the applicant's other pending requests**, mirroring `InvitationsController#reject_rest_of_invitations`, so an accepted applicant is not left with live applications elsewhere;
- refuses if the applicant has since become a captain (they may have created a team after applying) — the same reason as Task 2's refusal 1.

- [ ] Failing request spec → routes → actions → locales → run → mutations (strict guard swapped for the weak one **must** fail a cross-team example; drop the auto-reject and confirm; drop each mid-race clause and confirm) → commit.

---

### Task 4: Discovery — `TeamsController#index`

`resources :teams` already routes `index` and it currently 404s via `ActionNotFound`. Implementing it fills the slot with no route change.

- Authenticated. Lists teams with `includes(:captain, :members)` and an N+1 slope guard, same as phase 2's admin console.
- A "подать заявку" form per team, hidden for: the viewer's own team, viewers who are captains, teams with a pending request from this viewer, and mid-race teams.
- Linked from the dashboard's "no team" section **and** the team room, so both a teamless user and a member wanting to move can reach it.

- [ ] Failing request spec (including the hidden cases) → controller → view → locales → run → mutate each hiding condition → commit.

---

### Task 5: The captain's inbox in the team room

A block listing pending requests for this team with accept/reject buttons, rendered for the captain only.

**Strings must avoid** «Подать заявку на регистрацию» and «Отозвать» (see Frozen-suite exposure above). Use «Заявки на вступление», «Принять», «Отклонить».

- [ ] Failing view spec (captain sees it; plain member does not; empty when there are none) → view → locales → run → mutate the captain condition → commit.

---

### Task 6: Verification and PR

- [ ] Rebase, `bin/rails db:test:prepare`, full `rspec` (0 failures; roughly +40 examples), full `cucumber` (0 failures).
- [ ] `git diff origin/master --stat -- features/` prints nothing.
- [ ] **Re-read `registration-to-game.feature`'s two "Не капитан" scenarios and `team-room.feature`** before believing the suite — the team room is the one region this phase adds to that has frozen assertions.
- [ ] Update `docs/superpowers/queue.md`; push; `gh pr create --body-file`.
