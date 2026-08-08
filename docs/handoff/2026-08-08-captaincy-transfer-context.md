# Captaincy Transfer — Context Brief

**For:** whoever picks up "a team's captain can never be changed".
**From:** the session that found it, 2026-08-08, while answering an unrelated gameplay question.
**Status:** no design decided, no code written. This document is facts and decisions, not a plan.

Everything below was verified by reading the code, and every claim carries a `file:line`. Where I am
uncertain I say so. **Please re-verify anything load-bearing before you build on it** — this codebase
has repeatedly punished assumption, and a companion document
(`docs/security/2026-08-07-findings-register.md`) records eleven plan-authoring errors caught that
way in the preceding fortnight of work.

---

## 1. The problem is bigger than "captains should be able to hand over"

That is the polite framing and it is the least important case.

`TeamsController` has only `new` and `create` (`app/controllers/teams_controller.rb`), and
`:12` hardcodes `@team.captain = current_user`. **No code path anywhere reassigns `captain_id`
afterwards** — not a controller, not the admin console, not a rake task (`lib/` is empty), not a
migration. Confirmed exhaustively; the only other writes are in spec fixtures.

Now combine that with three other absences:

- **You cannot leave a team.** No route, no action, no view, no locale key. Verified by grepping
  `app/`, `config/locales/` and `features/` for every plausible spelling.
- **You cannot be removed from a team.** Same.
- **A team cannot be deleted.** `DELETE /teams/:id` routes (bare `resources :teams`,
  `config/routes.rb:65`) but `teams#destroy` does not exist — it raises
  `AbstractController::ActionNotFound`, i.e. a 404 *before* any filter.

So membership is **one team per user, permanently**. And captaincy is the only way to act on a team's
behalf.

**Therefore: if a captain abandons the game, deletes nothing, and simply stops logging in, their team
is bricked forever.** It can never register for a game, never invite anyone, never quit a race it is
already in. Its members cannot leave and cannot form another team, because
`TeamsController#ensure_not_member_of_any_team` (`:27-29`) refuses. There is no recovery in the UI,
no admin path, and no console helper.

**That is the real feature.** A self-service "captain hands over to a teammate" flow is nice and
solves none of it, because **every captaincy guard in the app asks "are you the captain"** — which is
useless precisely when the captain is the problem.

---

## 2. What captaincy actually controls

`User#captain?` (`app/models/user.rb:62-64`) is derived, not stored:

```ruby
def captain?
  member_of_any_team? && team.captain&.id == id
end
```

**Note it reads through `user.team`.** A user who is `teams.captain_id` of team A but whose
`users.team_id` is nil or points elsewhere is *not* a captain by this predicate. The two columns are
kept in sync only by `Team#adopt_captain` (`app/models/team.rb:23-26`), an `after_save` — see §5.

Captain-only capabilities, complete:

1. Invite a user to the team — `InvitationsController` `new`/`create`, gated at `:6`.
2. Register the team for a game — `GameEntriesController#new`.
3. Recall a pending application; 4. cancel an accepted one; 5. re-apply after recall/reject/cancel.
6. Withdraw the team mid-race — "Сойти с дистанции", `GamePassingsController#exit_game`, gated at `:30`.
7. Have a `phone_number` shown and editable on their profile (`app/views/users/index.html.erb:28`,
   `edit.html.erb:33`).
8. Be labelled captain in the team room, dashboard and profile.

**Not captain-only:** playing and entering codes (`ensure_team_member`), viewing the team room,
reading the full log after finishing.

Two different guards exist and the distinction matters:

- `SecurityFilters#ensure_team_captain` (`app/controllers/concerns/security_filters.rb:15-17`) — "is
  this user *a* captain". Weak. Safe today only because its callers derive the team from
  `current_user.team`.
- `GameEntriesController#ensure_captain_of_target_team` (`:91-96`) — "captain of *this* record".
  Strict, and written that way deliberately because that controller takes the team from the URL.

**If your design ever lets a user's `team_id` and the team they captain diverge, the weak guard
becomes exploitable.** `exit_game` is the one to watch.

---

## 3. What a captainless team does today

`Team belongs_to :captain, optional: true`, `captain_id` is nullable, and there is **no foreign key
and no index** on it (nor on `users.team_id`; the schema has no foreign keys at all). So
`captain_id IS NULL` and a dangling `captain_id` behave identically — `team.captain` returns nil.
Pinned by `spec/models/user/captain_spec.rb:49-60`.

**Fails closed (correct refusal):** `captain?` → false; `ensure_team_captain` → 401;
`ensure_captain_of_target_team` → 401 for every action; `adopt_captain` → no-op.

**Fails open (silently degraded, no error, no signal):** the dashboard renders "Вы состоите в
команде" for everyone; nobody carries the `- капитан` marker; the registration controls simply never
render, so the team never sees a way to apply; the ex-captain's phone field vanishes from their
profile while the value stays in the database.

**Raises a 500, and this one is a genuine bug you will have to fix:**
`NotificationMailer#accept_notification` / `#reject_notification`
(`app/mailers/notification_mailer.rb:50,58`) pass `team.captain` — nil — into
`mail_in_recipient_locale`, which dereferences `recipient.locale` (`:70`) and `recipient.email`
(`:73`). It is reachable: `InvitationsController#accept` is gated on being the *recipient*, not on
the team having a captain. Worse, the mailer call (`:37`) comes **after** the join (`:31`) and the
invitation delete (`:32`), so the user is already in the team and the invitation already gone when
the error page appears. `#reject` has the same shape.

**Any design that allows `captain_id` to be nil, even transiently, must fix that mailer path first.**

---

## 4. Decisions to make before writing code

These are product decisions. Do not guess at them; the repository owner is `mezinster`.

**Who can transfer?** Realistic options, not mutually exclusive:
- the captain, voluntarily, to a named member (solves the polite case only);
- a superadmin, from the admin console (solves everything, but the admin console has **no team
  management at all** today — `app/controllers/admin/` is `audit`, `dashboard`, `games`, `users` —
  so this is net-new surface, not an extension);
- automatic succession when the captain is provably absent (needs a definition of "absent" and a
  trigger; there is no `last_seen_at` on `users`).

**What happens to the outgoing captain?** They stay a member (there is no way to remove them). Their
`phone_number` becomes invisible and uneditable, though the stored value survives — see §6.

**Can transfer happen mid-game?** `GameEntry` and `GamePassing` belong to the *team*, and the guards
read `team.captain` live on every request, so a transfer instantly moves the "Сойти с дистанции"
button from one player's screen to another's while a race is running. Also `Game#reserve_place_for_team!`
/ `free_place_of_team!` mutate a limited-slot counter, so a new captain who does not understand the
state can burn a slot. Decide whether to forbid transfer while `GamePassing` is active.

**Should it be audited?** `AdminAction` is append-only, written today only by `InterventionsController`
and the admin games/users controllers. `AdminAction.label_for` already handles anything responding to
`name`, so `Team` works with no change, and a migration already added a details column "to hold the
team alongside a Game target". Cheap to wire up, and an operator will eventually need to explain a
forced transfer.

**Do you want co-captains or a nominated successor?** That is a schema change. Roles are strictly
binary today: membership is `users.team_id`, captaincy is `teams.captain_id`, and there is no role
column, no join table, and no team-scoped role of any kind. (`is_superadmin` is instance-wide.)

---

## 5. Landmines

**`adopt_captain` will steal a user from another team.** `app/models/team.rb:23-26` does
`members << captain` on `after_save` with no validation, and `members` is `has_many :users`, so it
overwrites that user's `team_id`. **Restrict the candidate set to `team.members`** or you will
silently move someone out of their own team.

**Writing `teams.captain_id` alone is not enough.** `captain?` requires `member_of_any_team?` first,
so the new captain's `users.team_id` must also point at that team. `adopt_captain` does this for you,
but only in the "add" direction.

**`PATCH /teams/:id` already routes** (`config/routes.rb:65`) and currently 404s via
`ActionNotFound` *before* any filter. Implementing `TeamsController#update` fills that slot with no
route change — convenient — but the whole `index`/`show`/`edit`/`destroy` set is exposed alongside it
and would remain 404-with-no-auth-check.

**There is no `spec/controllers/teams/create_spec.rb`.** The only code in the app that sets a captain
has no controller spec. Worth adding while you are here.

**About a third of the Cucumber suite logs in as `team.captain.nickname`** —
`features/game-passing/steps/game-passing_steps.rb:16,53,63,96,104`,
`features/games/steps/games_steps.rb:236,256,373`, `features/teams/steps/team_steps.rb:18`. Step
definitions *are* editable, but if any fixture path leaves `captain` nil these raise `NoMethodError`
rather than fail cleanly.

---

## 6. The frozen acceptance surface

**`features/**/*.feature` files must not be edited** except by explicit, recorded owner authorisation
(`CLAUDE.md`, "The acceptance-suite rule"). Two such authorisations exist, both recorded there. Assume
you get none.

The assertions that constrain this design:

- `features/teams/create-team.feature:12` — creating a team must immediately show **"Вы - капитан
  команды"**. `:42` and `:48` — an existing member *or captain* is refused at `/teams/new` and does
  not see the create button.
- `features/team-room/team-room.feature:28` — asserts the literal **`"Noel - капитан"`**. Exactly one
  member carries that marker.
- `features/invitations/send-invitations.feature:7` and `:12` — a captain sees "Пригласить
  участников"; a plain member does **not**. `:75` — a captain inviting themselves is refused as
  "already a member", which means **the captain is a member of their own team** and your design must
  preserve that invariant.
- `features/invitations/accept-invitations.feature:7,19` and `reject-invitations.feature:8,20` —
  four mail assertions whose recipient is resolved through `team.captain`. **Who the captain is at
  the moment of accept/reject is observable in the frozen suite.**
- `features/games/registration-to-game.feature:45,52` — a **non-captain** must not see "Подать заявку
  на регистрацию" or "Отозвать", on the dashboard or in the team room. Any transfer UI placed in
  those regions must not introduce text matching those strings.
- `features/game-passing/throw_in_the_towel.feature:32` — a plain member in a live game must **not**
  see "Сойти с дистанции".
- `features/games/user-profile-view-and-edit.feature:22,55` — a captain's profile shows and can edit
  "Контактный телефон"; `:8` and `:38` — a plain player's does not. **A transfer flips this for two
  users at once**, and nothing in the suite covers that moment.

---

## 7. Existing tests to extend rather than duplicate

- `spec/models/team/filters_spec.rb:21-39` — assigning an **external** user as captain both sticks
  and adds them to `members`. This is effectively a pre-existing transfer test; start here.
- `spec/models/user/captain_spec.rb` — four cases including a captainless team returning false
  rather than raising.
- `spec/requests/game_entry_authorization_spec.rb` — the sharpest existing coverage: a cross-team
  captain cannot recall, cancel, reopen or register another team, while the author can accept without
  being a captain at all.
- `spec/controllers/invitations/{new,create,accept,reject}_spec.rb`, `spec/controllers/game_entries/new_spec.rb:15`,
  and the view specs at `spec/views/{team_room,dashboard,users,game_passings}_spec.rb`.

---

## 8. Working conventions in this repository

Read `CLAUDE.md` first — it is short and every line of it is load-bearing. The ones that bite hardest:

- **Never edit a `.feature` file.** Step definitions are fair game.
- Ruby 3.3.12 via rbenv, **not on `PATH` in non-login shells**:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- New i18n keys go in **all four** of `config/locales/{ru,en,uk,ka}.yml`; `spec/i18n_spec.rb`
  enforces exact `ru`↔`en` parity. UI strings are Russian; code and comments are English.
- Hash rockets (`:key => value`) are the house style.
- Fixtures are plain helpers in `spec/spec_helpers/fixtures_helper.rb`. **No FactoryBot.**
- Cucumber takes ~170s. A subagent's Bash tool times out at 120s, so subagents cannot run it — have
  the coordinating session run it, or run it yourself in the foreground with a raised timeout.

**And the one habit worth adopting from the preceding work:** when you write a guard-style assertion,
break the code and watch it fail before you trust it. Four assertions in the recent security work
could not fail — including one that matched a comment rather than the code, and one comparing objects
whose class has no `#==`. None was caught by inspection; all were caught by mutation.
