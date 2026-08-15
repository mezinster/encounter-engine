# Inviting teams and solo players to a test run — design

**Date:** 2026-08-15. **Decided by:** repository owner (`mezinster`), in session.

## 0. The gap

An author who wants to rehearse a game clicks «Начать тестирование». Today exactly one team can
play the resulting run: the author's own. Everyone else is locked out, and not by a rule that could
be relaxed — by the absence of any path in.

`GamePassingsController#may_start_passing?` (`app/controllers/game_passings_controller.rb:391`) is
the gate:

```ruby
def may_start_passing?
  return false if @team.nil?
  return true if @game.is_testing? && @game.created_by?(current_user)

  GameEntry.of(@team, @game.current_run)&.status == "accepted"
end
```

The `is_testing?` exemption is deliberately scoped to the author's own team, and the comment above
it explains why an unscoped version would be a disclosure hole: `ensure_game_is_started` and
`ensure_not_author_of_the_game` both also return early on `is_testing?`, so widening this line
would let any authenticated user self-register a team and read every level and answer code of an
unpublished game.

The only other way in is an `accepted` `GameEntry` — and a testing game is hidden from
`app/views/shared/_current_games.html.erb:10`, while `start_test` nils `registration_deadline`
(`app/controllers/games_controller.rb:114`). So no second team can even request an entry.

This spec adds the missing path. **A superadmin can already start a test on anyone's game** —
`SecurityFilters#ensure_author` returns early for superadmins
(`app/controllers/concerns/security_filters.rb:31-32`) — so the "or superadmin" half of the request
needs no new permission, only the same treatment on the new actions.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | Who may be invited? | Existing teams **and** individual players. Solo is the common case. |
| D2 | Is solo play available in real games? | **No. Test runs only.** Real runs stay team-only, unchanged. |
| D3 | How are invitees admitted? | By name, author-initiated, **with no acceptance step** — and additionally via a **run-scoped test link** that `finish_test` revokes. |
| D4 | What about an invitee who already belongs to a real team? | They play solo in a **disposable team**; `users.team_id` is never written. `find_team` becomes test-aware. |
| D5 | Where is admission recorded? | A new `test_admissions` table, **not** a new `GameEntry` status. |
| D6 | Does a test admission consume a registration slot? | No. `reserve_place_for_team!` is never called. |
| D7 | Can a solo tester quit the run themselves? | No. The exit control is hidden for them; the author's revoke is the way out. |

### D2 — why "test only" changed the design rather than merely constraining it

Teaching `GamePassing` about users (a nullable `user_id`) was the obvious move and is rejected.
Every real-game path — standings, `place_of`, the results page, `Team#in_live_race?`, the operator
intervention console — would need a permanent "but not solo" assertion, and that invariant would
live in a dozen files forever, each one a place to forget it.

With a disposable one-person team, **solo play *is* team play**. The play machinery is unchanged;
the only new rule is who may conjure such a team, and that rule is confined to `is_testing?` and
swept by `finish_test`. One narrow gate beats a scattered invariant.

### D4 — why a disposable team cannot simply take the user as a member

`users.team_id` is a single column and `GamePassingsController#find_team` is literally
`@team = current_user.team` (`:313-315`). A user belongs to exactly one team.

So the naive implementation — create a team, make the tester its captain — **steals a real player
out of their real team**. `Team#adopt_captain` (`app/models/team.rb:131`) does `members << captain`,
which writes `users.team_id`; `captain_is_not_another_teams_member` would either refuse the save or
the write lands and the tester's real team is left captainless. That is precisely the bricked-team
state the 2026-08-08 team-membership programme exists to eliminate
(`docs/superpowers/specs/2026-08-08-team-membership-programme-design.md`).

A disposable team therefore has **no members and no captain**. It exists only as the subject of a
`GamePassing`, and the tester is connected to it by the admission row, not by membership.

This is also what makes D4 worth doing at all. The people an author actually wants testing are
co-authors and trusted players — exactly the population that already has teams. Restricting solo
play to the teamless would have shipped the feature to the wrong half of the users.

### D5 — why a new table rather than a `GameEntry` status

Reusing `GameEntry` with `status: "test"` looks cheaper and survives first inspection: the partial
unique index is scoped to `status IN ('new','accepted')` (`db/schema.rb:90`), so test rows cannot
collide, and capacity accounting stays correct as long as `reserve_place_for_team!` is never called.

It is rejected on two grounds.

**It adds an unreachable state to a state machine whose invariants are already delicate.** No
transition — `accept!`, `reject!`, `recall!`, `cancel!` — produces or leaves `"test"`, and
`GameEntry.of` deliberately prefers `"accepted"` over everything else, with a comment recording a
production bug where a rejected row shadowed an accepted one. Adding a fifth status means re-reading
every `with_status` and `of` caller to prove it is unaffected.

**The sweep stops being a query and becomes an argument.** `finish_test` is the only thing standing
between a test run and the real game. Its existing comment (`app/controllers/games_controller.rb:222-228`)
records a near-miss where `delete_all` on a `has_many` proxy would have *nullified* foreign keys
rather than deleting rows — a wipe indistinguishable from success in every count. With a dedicated
table, "what did this test create?" is `WHERE game_run_id = ?`. With a status flag it is "entries
with a status that means test, plus teams that are implicitly disposable."

## 2. Data model

### 2.1 `test_admissions`

| column | type | notes |
|---|---|---|
| `game_run_id` | integer, not null | Admission belongs to one *running* of the game, matching `GameEntry`'s run-scoping |
| `team_id` | integer, not null | The team that will actually play. Always present, so the play path stays uniform across both invitee kinds |
| `user_id` | integer, **nullable** | Set **iff** this is a solo admission. The nullability is the type discriminator |
| `created_at` | datetime, not null | |

Indexes:

- `[game_run_id, team_id]`, unique — a team is admitted to a run at most once.
- `[game_run_id, user_id]`, unique, partial on `user_id IS NOT NULL` — a user holds at most one solo
  admission per run. The partial clause is required: without it, two team admissions (both
  `user_id` NULL) would collide on SQLite and Postgres alike.

`team_id` is not null deliberately. Modelling a solo admission as "a user with no team yet" would
push the disposable-team creation into the play path, where it would run inside a GET request and on
every retry.

### 2.2 `TestAdmission`

```ruby
class TestAdmission < ApplicationRecord
  belongs_to :game_run
  belongs_to :team
  belongs_to :user, optional: true

  scope :of_run,  ->(run)  { where(:game_run_id => run.id) }
  scope :solo,    ->       { where.not(:user_id => nil) }

  validate :run_is_testing, :on => :create

  def solo?
    user_id.present?
  end
end
```

`run_is_testing` refuses creation unless `game_run.is_testing?`. Validated on create only: an
admission that outlives the flag for a moment during teardown must not raise on an unrelated save.

`GameRun has_many :test_admissions, dependent: :destroy`, which makes deletion cascade correctly
through the existing `Game has_many :runs, dependent: :destroy`.

### 2.3 `game_runs.test_token`

Nullable string, unique index. `SecureRandom.urlsafe_base64(24)`, written by `start_test`, set to
`nil` by `finish_test`, and regenerable by the author (which revokes the previous link).

24 bytes is chosen over the 16 that would also be adequate because the token is the sole credential
protecting an unpublished game's answer codes, and the cost of the extra characters is nil.

### 2.4 Disposable teams

No new column on `teams`. A disposable team is recognised by being named from a solo admission, and
teardown deletes it **only if `Team#deletable?` agrees** (`app/models/team.rb:74`). That method
already refuses any team holding members, a captain, game entries, passings, or logs — so a real
team can never be swept even if an admission somehow pointed at one. Reusing the existing guard is
strictly safer than a `disposable` boolean, which a bug could set on the wrong row.

**Naming.** `teams.name` is `validates :name, uniqueness: true` (`app/models/team.rb:20`), so the
generated name must be collision-proof rather than decorative:

```
"#{user.nickname} (test ##{run.id})"
```

with a bounded numeric-suffix retry (`-2`, `-3`, … up to 10) if a real team happens to hold that
literal name. The marker is ASCII and untranslated on purpose: this is stored data, and an i18n'd
name would freeze whichever locale the inviting author was using into a row read by everyone else.
It is visible on the play screen and in the run's log lines, which is acceptable — and arguably
useful — inside a test.

## 3. Admission

### 3.1 By name

Rendered on `games#show` while `is_testing?`, visible to the author or a superadmin: a panel listing
current admissions with a revoke button, plus **two separate submissions** —

- **Invite team** — find `Team` by name → admission with `user_id` nil. The team plays as itself,
  with its real members.
- **Invite player** — find `User` by nickname → create disposable team → admission with `user_id`
  set.

Two fields rather than one clever field that guesses: a team and a user may share a name, and
guessing wrong silently admits the wrong party to an unpublished game.

Refusals, each with its own message:

- name not found;
- the named user is the game's author (already exempt — nothing to grant);
- the named team is already admitted, or the named user already holds a solo admission — reported as
  a notice, not an error. Both actions are idempotent.

**A team currently racing in a real game is admitted without objection**, and this is deliberate
rather than unconsidered. The test passing lives in a different run, so it cannot disturb the real
one, and `Team#in_live_race?` is already true for such a team — the test changes nothing it reports.
`finish_test` then deletes the test passing, restoring the prior state exactly.

### 3.2 By link

The link is `GET /games/:game_id/test/:token`. Opening it does **not** create the admission.

`GET` renders a confirmation page naming the game and offering a POST button; the POST creates the
solo admission and redirects to play. This is the same reasoning `config/routes.rb:205-213` records
for `start_test`/`finish_test`/`end_game`: this app has no Turbo and no rails-ujs, mutating requests
are POSTs driven by `button_to`, and a state-changing GET is reachable from any forwarded or
prefetched URL.

The confirmation step matters more here than for those three, because the link is *designed* to be
pasted into a chat: without it, a link preview bot that follows the URL would silently admit whatever
account it was authenticated as.

Guards on both halves: authenticated, the run `is_testing?`, and the token matches. A user who
already holds an admission is redirected straight to play. The author opening their own link is
likewise sent to play — they need no admission.

Token comparison uses `ActiveSupport::SecurityUtils.secure_compare` after the indexed lookup.

## 4. Play-time identity

`find_team` gains a test branch. Nothing else in the play path changes:

```ruby
def find_team
  @team = test_admission&.team || current_user.team
end

def test_admission
  return nil unless @game&.is_testing?

  @test_admission ||= TestAdmission.find_by(:game_run_id => @game.current_run.id,
                                            :user_id     => current_user.id)
end
```

`find_team` already runs after `find_game` (`:5` then `:9`), so it may consult
`@game.current_run` without reordering the filter chain — which matters, because that ordering
carries a 25-line comment about hint clocks being stamped at the wrong moment.

`may_start_passing?` gains one clause, and it covers **both** invitee kinds because an admission
always names a team:

```ruby
return true if @game.is_testing? &&
               TestAdmission.exists?(:game_run_id => @game.current_run.id, :team_id => @team.id)
```

### 4.1 Two filters need admission-scoped exemptions

**`ensure_team_member`** (`app/controllers/game_passings_controller.rb:40`) raises unless
`current_user.member_of_any_team?`, which reads `users.team_id` — the exact column this design is
careful never to write. Without an exemption it 401s every teamless solo tester, *after* the
admission, the disposable team and `find_team` have all worked correctly. The exemption is scoped to
"holds an admission in this testing run", never to `is_testing?` broadly.

**`ensure_team_captain, only: [:exit_game]`** (`:36`) — a solo tester captains nothing. Rather than
weaken a captain check, the exit control is **hidden** for solo participants (D7). Weakening a
captain guard to serve a test is the same trade `GameEntriesController#ensure_captain_of_target_team`
(`:102-119`) documents as the root of a cross-tenant hole.

`ensure_game_is_started` and `ensure_not_author_of_the_game` already return early on `is_testing?`
and need no change. `app/views/game_passings/show_current_level.html.erb:83` already reads
`current_user.captain? || @game.is_testing?`, so the answer form renders for a non-captain tester
without modification.

### 4.2 Reaching the game

A new `app/views/shared/_test_runs.html.erb`, rendered on the dashboard, lists runs the current user
holds an admission in.

It cannot be folded into `_current_games.html.erb`: that partial is wrapped in
`if current_user.member_of_any_team?` at line 1 — false for a teamless tester — and skips testing
games at line 10.

## 5. Teardown and revocation

### 5.1 `finish_test`

The sweep appends to the existing deletions, and **the order is load-bearing**: passings must be gone
before `Team#deletable?` is consulted, or every disposable team still holds one and reports itself
undeletable, leaving the whole cohort behind. The existing pair at
`app/controllers/games_controller.rb:229-230` already runs first:

```ruby
GamePassing.where(:game_run_id => run.id).delete_all   # existing
Log.of_run(run).delete_all                             # existing
                                                       # --- new, in this order ---
admissions = TestAdmission.where(:game_run_id => run.id)
solo_teams = admissions.where.not(:user_id => nil).map(&:team)
admissions.delete_all
solo_teams.each { |team| team.destroy if team.deletable? }
run.update_column(:test_token, nil)
```

Three details in those five lines are not interchangeable with the obvious alternatives.

**`TestAdmission.where(...)`, not `run.test_admissions`.** `delete_all` on a `has_many` proxy
*nullifies* the foreign key rather than deleting rows unless the association declares
`dependent: :delete_all` — the exact trap `finish_test`'s existing comment records. Here
`game_run_id` is `NOT NULL`, so it would raise rather than silently corrupt, but a design that
relies on a constraint to catch a known mistake is one migration away from not catching it.

**Teams are collected before the admissions are deleted, and destroyed after.** Destroying a team
while a row still references it leaves a dangling `team_id`; deleting the admissions first loses the
list. Collect, delete, destroy.

**`deletable?` is evaluated after the passings are gone.** The teams in `solo_teams` are freshly
loaded with unloaded associations, so `game_passings.empty?` and `Log.where(team_id:)` hit the
database in their post-deletion state. Evaluating `deletable?` on team objects cached from earlier in
the request would consult stale associations and spare every team.

`update_column`, matching every other lifecycle writer on this model: a game mid-test does not pass
its own validations (`game_starts_in_the_future` fires on any game whose start date has passed), and
`update` would fail silently — the trap documented on `Game#pause!`.

### 5.2 Revoke

Revoking one admission performs the same three steps for that row, **including deleting the team's
run-scoped `GamePassing`**.

This is not tidiness. `find_or_create_game_passing`
(`app/controllers/game_passings_controller.rb:368-370`) returns early the moment a passing exists:

```ruby
@game_passing = @game.current_run.passing_for(@team)
return @game_passing if @game_passing
```

`may_start_passing?` is consulted **only when there is no passing yet**. Deleting an admission from
someone already playing would therefore change nothing at all — they would keep playing while the
admissions panel showed them removed. A revoke that does not delete the passing is a button that
lies.

## 6. Routes, controller, authorization

```ruby
post   "/games/:game_id/test_admissions/team",   to: "test_admissions#create_team",   as: :test_admit_team
post   "/games/:game_id/test_admissions/player", to: "test_admissions#create_player", as: :test_admit_player
post   "/games/:game_id/test_admissions/:id/revoke", to: "test_admissions#revoke",    as: :revoke_test_admission
post   "/games/:game_id/test_token",             to: "test_admissions#reset_token",   as: :reset_test_token
get    "/games/:game_id/test/:token",            to: "test_admissions#invite",        as: :test_invite
post   "/games/:game_id/test/:token",            to: "test_admissions#join",          as: :join_test
```

All mutations are POST driven by `button_to`, matching the reasoning at `config/routes.rb:205-213`.

`TestAdmissionsController` filter chain for every action except `invite`/`join`:

```
require_authentication! → find_game → ensure_author → ensure_editing_not_locked → ensure_game_is_testing
```

`ensure_author` already admits superadmins (`security_filters.rb:31`), which satisfies the
superadmin half of the requirement with no new permission concept.

`ensure_editing_not_locked` is included deliberately: it already covers `start_test`/`finish_test`,
and its comment explains that a locked author must not be able to erase the evidence an operator
locked the game to investigate. Admitting fresh testers to a locked game is the same class of act.

`invite`/`join` are the deliberate exception — any authenticated user, gated by the token and
`is_testing?` alone.

Operator actions record an audit entry via `record_admin_action` when `acting_as_operator?(@game)`,
matching `start_test` and `finish_test`.

## 7. i18n

New keys go into **all seven** locale files (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`). `ru` and `en`
must reach exact parity or `spec/i18n_spec.rb` fails; the other five may lag but should not.

Any key interpolating a nickname or a team name follows the Turkish rule recorded in `CLAUDE.md`:
the case suffix attaches to a common noun, never to the placeholder — `«%{team}» adlı takım`, not
`%{team}'a`. Georgian gets the same restructuring. Check each by rendering with a consonant-final and
a vowel-final name.

No key here needs pluralisation, so no `one:`/`few:`/`many:` forms are introduced.

## 8. Testing

**RSpec only. No `.feature` file is created or edited.** `features/games/test-game-1.feature` and
`test-game-2.feature` exercise start/finish of a test run and must stay green unchanged — they are
the regression check that this feature did not disturb the existing flow.

The specs that earn their place:

| Claim | Why it is the one worth pinning |
|---|---|
| A solo admission never writes `users.team_id` | The entire D4 design in one assertion. Assert the invitee's `team_id` before and after, including for an invitee who already captains a real team. |
| Revoke stops play mid-test | Pins §5.2 — assert the `GamePassing` is gone, not merely the admission, then assert the next request is refused. |
| `finish_test` leaves nothing behind | Zero admissions, zero disposable teams, `test_token` nil — and the invitee's real team still intact. |
| A non-admitted user is still refused | The disclosure hole `may_start_passing?`'s comment warns about. Assert `Unauthorized` for an authenticated stranger on a testing game. |
| The link dies with the test | `GET` the token URL after `finish_test`; expect refusal, not a fresh admission. |
| Admitting a real team consumes no slot | `requested_teams_number` unchanged (D6). |
| Teardown never deletes a real team | Point an admission at a real team, run `finish_test`, assert the team survives — proves the `deletable?` guard, not just the happy path. |

Order dependence in `finish_test` (§5.1) is worth its own example: assert the disposable team is gone
after a test in which the tester **actually played**, since that is the case a wrong order breaks and
an unplayed test would pass either way.

## 9. Out of scope

- Email notification of an invitation. D3 chose no acceptance step; the author tells testers out of
  band, which is what they do today.
- Solo play in real games (D2), and any per-invitee choice of "as their team or solo" (rejected
  during design as UI surface with no clear demand).
- Reusing an admission across runs. Admissions are run-scoped, and a second run re-invites.
