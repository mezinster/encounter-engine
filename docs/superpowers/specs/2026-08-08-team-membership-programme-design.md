# Team membership programme — design

**Date:** 2026-08-08. **Decided by:** repository owner (`mezinster`), in session.
**Supersedes no design; originates from** the context brief in PR #38
(`docs/handoff/2026-08-08-captaincy-transfer-context.md`), which deliberately proposed no design.

This document covers six sub-projects that share one data model and one set of guards. They are
specified together because their interdependencies are the whole difficulty; they are **built
separately**, in the phase order of §7, each with its own implementation plan.

---

## 1. The problem

A team's captain can never be changed. Combined with three other absences — you cannot leave a team,
you cannot be removed from one, and a team cannot be deleted — a captain who simply stops logging in
**bricks their team permanently**. It can never register for a game, never invite anyone, never quit
a race it is already in, and its members can never form another team because
`TeamsController#ensure_not_member_of_any_team` refuses them.

Every captaincy guard asks *are you the captain*, which is useless precisely when the captain is the
problem. So the recovery path must be a non-captain path.

**Verified independently for this design** (the brief asks that load-bearing claims be re-checked):

- `app/controllers/teams_controller.rb:12` is the **only** production write of `captain` anywhere —
  no other controller, no rake task, no migration. A captainless team therefore cannot arise today
  except by direct database manipulation, which makes the mailer crash below **latent, not a live
  incident**.
- `NotificationMailer#accept_notification` passes `team.captain` into `mail_in_recipient_locale`,
  which dereferences `recipient.locale` and `recipient.email`. `InvitationsController#accept` joins
  the invitee and deletes the invitation *before* calling it, so a nil captain means a partial commit
  plus an error page, and `reject_rest_of_invitations` never runs.
- `Team#adopt_captain` (`app/models/team.rb:23-26`) is an `after_save` running on **every** save that
  does `members << captain` with no validation, silently overwriting that user's `team_id`.
- `User#captain?` (`app/models/user.rb:62-63`) reads through `user.team`, so writing `teams.captain_id`
  alone does not make anyone a captain.
- `invitation.rb:14` validates `recepient_is_not_member_of_any_team`; `admin_actions.actor_id` is
  `null: false` in the schema but `belongs_to :actor, optional: true` in the model;
  `last_superadmin_keeps_the_role` fires only on `is_superadmin_changed?(from: true, to: false)` and
  so is bypassed by `destroy`; `app/views/games/show.html.erb:14` dereferences `@game.author.nickname`
  unguarded, with no `dependent:` on `User#created_games`.

## 2. Decisions

All five were put to the repository owner and answered on 2026-08-08.

| # | Decision | Answer |
|---|---|---|
| D1 | What is allowed while a team has an active `GamePassing`? | **Superadmin captaincy reassignment only.** Member-initiated leaves, join-request approvals, and consent-free moves are refused mid-race. Rationale: the abandoned-captain problem is most acute mid-race, because quitting is itself captain-only. |
| D2 | Self-service handover, or superadmin only? | **Both.** A captain may hand over voluntarily; a superadmin may reassign regardless. |
| D3 | May a user leave a team without joining another? | **Yes.** Plain leave exists. |
| D4 | What does user deletion do? | **Both operations, separately:** a guarded hard delete for housekeeping, and a distinct anonymise that preserves rows. |
| D5 | A solo captain (only member) wants to leave? | **Allowed; the team becomes an inert tombstone** — no members, no captain, all history preserved. |

D5's consequence is deliberate and accepted: an empty captainless team is inert (every guard fails
closed), nobody is trapped in it, and its `GamePassing`, `GameEntry` and `Log` history survives. Two
accepted costs: the team's name stays reserved (`Team` validates `name` uniqueness), and **F3 below
becomes load-bearing rather than precautionary**, because a pending invitation to that team can still
be accepted.

## 3. Foundations

These are cross-cutting and land first (phase 1).

### F1 — `Team#set_captain!(member)`

The single operation through which captaincy ever changes. It validates that the target is in
`team.members`, assigns `captain_id`, and **never nils it**. A non-member raises `ArgumentError`,
matching the refusal style of the `GamePassing` operator interventions
(`app/models/game_passing.rb`), which `InterventionsController` already rescues.

Rationale: one chokepoint makes §5's theft landmine unreachable from our code and enforces the frozen
"a captain is a member of their own team" invariant (see §6) in one place rather than at four call
sites. There is deliberately **no revoke operation** — a bare revoke produces exactly the bricked
state this programme exists to remove.

### F2 — Narrow `Team#adopt_captain`

Change it to refuse to adopt a user who already belongs to a **different** team, while still adopting
a teamless one.

It cannot simply be deleted: `TeamsController#create` assigns `captain = current_user`, who has no
`team_id` yet, so adoption is what makes a team's creator a member. Only the *theft* case is the bug.

**Checked for this design:** `spec/models/team/filters_spec.rb:21-39` ("assigning an 'external' user
as a captain") builds its captain with a bare `create_user` — a user with **no team**. F2 therefore
preserves that spec unchanged: a teamless user is still adopted. The spec is not, as the brief's
phrasing might suggest, coverage of the theft case; **nothing currently pins the theft behaviour**,
which is why F2 needs a new spec of its own.

### F3 — Guard the mailer against a captainless team

In `NotificationMailer#accept_notification` and `#reject_notification`, return before calling `mail`
when `team.captain` is nil. A mailer method that never calls `mail` yields `NullMail`, so the
existing `deliver_now` becomes a no-op and the controller flow is unchanged.

Chosen over reordering `InvitationsController#accept` because the ordering is itself deliberate and
commented; the defect is the unguarded dereference, not the sequence.

### F4 — `actor_label` on `AdminAction`, backfilled

Mirrors the existing `target_label` snapshot, which carries a comment explaining that "a number
nobody can resolve" is the worst possible audit outcome. Without it, deleting an operator turns every
action they ever took into an unattributable row, in a log documented as append-only.

**Sequenced immediately before deletion (phase 6), not first.** Nothing deletes users today, so no
history is at risk while it waits, and front-loading it would delay the change that actually unbricks
teams. This is a deliberate departure from the build order suggested in the brief.

## 4. The six sub-projects

### S1 — Reassign captaincy (phase 2)

Two entry points onto `F1`:

- **Superadmin:** a net-new `Admin::TeamsController` (`index`, `set_captain`). The admin console has
  no team management at all today — `app/controllers/admin/` is `audit`, `dashboard`, `games`,
  `users` — so this is new surface, not an extension. Audited via `record_admin_action`;
  `AdminAction.label_for` already accepts anything responding to `name`, so `Team` works unchanged.
- **Captain self-service:** `POST /teams/:id/hand_over` from the team room, target chosen from
  `team.members`.

Per **D1**, the superadmin path is permitted mid-race; the self-service handover is refused while the
team has an active `GamePassing`.

### S2 — Superadmin moves a user between teams (phase 3)

Sets `users.team_id` directly, audited, no consent required. Refused when the user is a captain, with
the refusal naming reassignment as the remedy — keeping that ordering visible in the UI, or an
operator meets "cannot move: this user is a captain" with no hint at the fix. Refused when either the
source or the destination team is mid-race (**D1**).

### S3 — Leaving a team (phase 4)

`POST /teams/leave`, setting `team_id` to nil. Refused if the user is a captain — they must hand over
or be reassigned first — and refused mid-race (**D1**). Per **D5**, a solo captain is the one case
allowed to leave while holding the role, which empties the team.

`ensure_not_member_of_any_team` stays exactly as it is; it simply stops being a permanent trap.

### S4 — Join requests (phase 5)

New model `TeamJoinRequest(user, team, status)` mirroring `GameEntry`'s `new`/`accepted`/`rejected`
status shape, approved by the **target team's** captain.

It cannot reuse `Invitation`: that model validates `recepient_is_not_member_of_any_team`, and three
frozen scenarios pin the refusal (§6). It also points the wrong way — `Invitation` is captain → user,
a join request is user → captain.

Approval is guarded by the **strict** `ensure_captain_of_target_team` pattern from
`GameEntriesController:91-96`, never the weak `SecurityFilters#ensure_team_captain`, which only asks
"is this user *a* captain" and would let the captain of team A approve a request addressed to team B.
Accepting detaches the user from their current team. Refused mid-race on either side (**D1**).

### S5 — User deletion (phase 6)

Hard delete in `Admin::UsersController`, audited, refused when the user:

- **is a captain** — dangling `captain_id` is the bricked-team state; point the operator at S1;
- **is the last superadmin** — mirror `last_superadmin_keeps_the_role` onto `destroy`, which it does
  not currently cover;
- **has authored games** — games are content other people played, so orphaning them (and 500ing
  `games/show.html.erb:14`) or deleting them are both wrong.

### S6 — Anonymise a user (phase 6)

A distinct operation from S5, per **D4**: scrub email, nickname, phone number and contact handles
while keeping the row, so authored games, audit rows and race history survive intact and attributable
in shape. Needs a collision-free nickname placeholder, since `nickname` carries a uniqueness
validation.

## 5. Landmines carried forward from the brief

- **`adopt_captain` steals users.** Addressed by F1 + F2.
- **Writing `teams.captain_id` alone is not enough** — `captain?` requires `member_of_any_team?`
  first, so the new captain's `users.team_id` must point at that team. F1's member-only rule
  guarantees this by construction.
- **`PATCH /teams/:id` already routes** (bare `resources :teams`, `config/routes.rb:65`) and currently
  404s via `ActionNotFound` before any filter. Implementing actions fills those slots with no route
  change — convenient, and a hazard if an action is added without a guard.
- **About a third of the Cucumber suite logs in as `team.captain.nickname`.** A fixture path that
  leaves `captain` nil raises `NoMethodError` in step definitions rather than failing cleanly.
- **There is no `spec/controllers/teams/create_spec.rb`** — the only code in the app that sets a
  captain has no controller spec. Add one in phase 1.

## 6. The frozen acceptance surface

`features/**/*.feature` must not be edited (CLAUDE.md). **Assume no authorisation is granted.**

**Citation note:** the line numbers in the PR #38 brief point at *scenario headers*, not at the
assertions themselves, which sit a few lines below (e.g. "Вы - капитан команды" is
`create-team.feature:19`, under the scenario at `:12`). The constraints below were re-verified by
string, not by line, and all of them hold. Cite scenarios by name when writing plans.

| Scenario | Constraint it imposes |
|---|---|
| `teams/create-team.feature` — "Пользователь создаёт команду" | Creating a team must immediately show "Вы - капитан команды" (`:19`). |
| `create-team.feature` — the two "Действующий член или капитан" scenarios | A current member or captain is refused at `/teams/new` and does not see the create button. Checked: S3 does **not** collide — these concern users who are *currently* members. |
| `team-room/team-room.feature` — "В комнате команды отображается имя её капитана" | Exactly one member carries the captain marker. |
| `invitations/send-invitations.feature` | A captain sees "Пригласить участников"; a plain member does not. The not-a-member refusal, and with it the invariant that **a captain is a member of their own team** — which F1 enforces. |
| `accept-invitations.feature`, `reject-invitations.feature` | Four mail assertions resolving their recipient through `team.captain`, so **who the captain is at accept/reject time is observable**. |
| `games/registration-to-game.feature` — the two "Не капитан" scenarios | A non-captain must not see "Подать заявку на регистрацию" or "Отозвать" on the dashboard or in the team room. **New team-room strings for S1 must not match these.** |
| `game-passing/throw_in_the_towel.feature` — "Игрок не может снять команду с дистанции" | A plain member in a live game must not see "Сойти с дистанции" (`:36`). |
| `user-profile-view-and-edit.feature` | A captain's profile shows and can edit "Контактный телефон"; a plain player's does not. **A transfer flips this for two users at once**, and nothing in the suite covers that moment. |

## 7. Build order

Each phase is a separate implementation plan, branch and PR.

1. **Foundations** — F1, F2, F3, plus the missing `TeamsController#create` spec.
2. **S1** — reassign captaincy: admin console surface + captain self-service.
3. **S2** — superadmin moves between teams. Depends on S1 for the captain-must-be-reassigned rule.
4. **S3** — leaving a team. Depends on S1 for the same reason.
5. **S4** — join requests. Depends on S3, since accepting detaches.
6. **F4 + S5 + S6** — `actor_label`, then deletion and anonymise. Depends on S1 for the captain guard.

## 8. Out of scope

- **Co-captains or a nominated successor.** A schema change; roles are strictly binary today
  (`users.team_id` for membership, `teams.captain_id` for captaincy, no role column, no join table).
- **Automatic succession on captain absence.** There is no `last_seen_at` on `users`, so "absent" has
  no definition to trigger on.
- **Team deletion.** Rejected under D5: it forces a cascade decision on `GamePassing`, `GameEntry` and
  `logs.team_id` — records of races other people ran — which is the same objection that rules out
  deleting authored games.
