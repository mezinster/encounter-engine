# Access-gated commercial games — design

**Date:** 2026-08-18. **Decided by:** repository owner (`mezinster`), in session.
**Sub-project B of** `docs/superpowers/specs/2026-08-18-commercial-games-programme-design.md`.
**Depends on** sub-project A (`2026-08-18-operator-role-design.md`), which shipped the
`operator` role inert. B is where that role acquires its authority.

## 0. The gap

A game is playable here only by a team the author accepted into a scheduled run, and only while
that run is running. Two mechanisms enforce it, and both are wrong for a game sold as a unit:

`GamePassingsController#find_or_create_game_passing` (`:525`) resolves the attempt as
`@game.current_run.passing_for(@team)` and gates creation on an `accepted` `GameEntry` in that run
(`may_start_passing?`, `:548`). `ensure_game_is_started` (`:625`) refuses any game whose current
run has no past `starts_at`.

A commercial game has no cohort and no schedule. Its customers arrive one at a time, whenever they
bought a pass, and each is entitled to exactly one run of their own. This spec adds that path.

**B is deliberately proven with operator invitations only.** No access codes: those are
sub-project C, and separating them means the play-path surgery below lands without code
generation, digest storage or an export UI in the same diff.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| B1 | What vocabulary does B introduce? | Two columns on `games`: `visibility` and `access_mode`. **Not** `scoring_mode` — that is sub-project D's. |
| B2 | What are the values? | `visibility`: `draft` / `listed`. `access_mode`: `scheduled` / `pass_required`. Withdrawal stays a separate fact — see B2a. |
| B2a | Is `hidden` a visibility value? | **No.** `withdrawn_at` remains authoritative for it. Draft-ness and withdrawn-ness are orthogonal, and the suite pins their combination. |
| B3 | Why `pass_required` rather than `access_code`? | The rule is "a team needs an entitlement"; a code is one way to get one, and in B the only way is an operator invitation. |
| B4 | Where does the entitlement live? | A new `access_passes` table. Both `game_id` and `team_id` NOT NULL — a pass is always somebody's. |
| B5 | What is a commercial attempt, physically? | A `GamePassing` with `game_run_id` NULL and `access_pass_id` set. Programme decision P5, unchanged. |
| B6 | May a team hold several live passes for one game at once? | **Yes, any number.** Each attempt consumes the **oldest** live pass. |
| B7 | Do commercial games have standings? | **Yes** — per game, across all passes, **one row per completed attempt**, ranked by duration. |
| B8 | What is "duration"? | `finished_at − created_at − paused_seconds + penalty_seconds`. `paused_seconds` is a new column. |
| B9 | How is a runless attempt's log addressed? | A new `logs.game_passing_id`, backfilled. `(game_id, team_id)` cannot distinguish a team's second pass from its first. |
| B10 | What does `Game#status` report? | A new `:available`, slotted between `:finished` and `:running`. |
| B11 | What may an operator revoke? | A pass with **no attempt**. Revoking a started pass is refused; a started run is an intervention. |
| B12 | Does anything about scoring, hints or answers change? | **No.** The gate stays at passing creation, so the whole play loop is indifferent to how the team got in. |

### B1/B2 — what `visibility` replaces, and what it deliberately does not

Today "may a player see this?" is answered by `Game.visible` (`app/models/game.rb:115`) as three
conditions: `is_draft = false`, `withdrawn_at IS NULL`, and no run with `is_testing`. That scope's
own comment records the cost of leaving the first one implicit — `start_test` clears `is_draft` to
make a test game behave as live, which silently retired the draft protection at the moment the game
was an unpublished rehearsal, and the game appeared on the public home page as RUNNING (reported
from production 2026-08-15).

`visibility` replaces **`is_draft` only**, as a named two-value column: `draft` / `listed`.

### B2a — why `hidden` is not a third value

The obvious next step is to fold withdrawal in as `visibility: hidden` and demote `withdrawn_at` to
a timestamp. It cannot be done, and the codebase says so in two places.

`spec/models/game/status_spec.rb:88` pins **"reports :withdrawn for a draft that has also been
withdrawn"**, with a comment explaining that `Game#status` checks withdrawal before it looks at
draft-ness, that the precedence is positional, and that swapping the two `return`s would make a
withdrawn draft report `:draft` while `count_by_status` still counted it as `:withdrawn`. A
precedence that has to be declared between two conditions is evidence that they are independent
facts, not points on one scale.

The practical consequence is `restore!`. With one column it has nothing to restore *to*: a
withdrawn game may have been a draft or may have been listed, and `hidden` erases the difference.
The alternatives were a second column existing only to undo the first, or refusing to withdraw a
draft — which deletes a tested state to tidy a column.

So withdrawal keeps its own column and its own meaning: `withdrawn_at` is an operator act with a
timestamp the audit trail already reads, and it is orthogonal to whether the author has published
the game.

```ruby
scope :visible, -> {
  where(:visibility => "listed")
    .where(:withdrawn_at => nil)
    .where.not(:id => GameRun.where(:is_testing => true).select(:game_id))
}
```

Three conditions still, one of them now named rather than inferred from a boolean called
`is_draft`. `Game#status`'s ladder and its precedence comment are unchanged apart from the new
`:available` rung (§7).

The riskiest single edit in this migration is `start_test`/`finish_test`
(`app/controllers/games_controller.rb:111`, `:222`), which flip `is_draft` as a side effect.
Verified: `finish_test` sets it back to `true` **unconditionally** — a tested game always returns
to draft, whatever it was before — so both become straight renames onto `visibility` with no
restore-the-previous-value logic. Preserve that behaviour exactly; it is deliberate (you rehearse
before publishing) and changing it would silently publish a game when its test ended.

### B3 — the two columns are independent

A commercial game is `visibility: listed, access_mode: pass_required`: publicly listed, privately
playable. A withdrawn commercial game is legal and behaves as any withdrawn game does — pulled from the
catalog, unplayable — and no validation forbids any combination of the two columns. `scheduled` games are every game that exists today; the
migration backfills `access_mode = "scheduled"` for all of them.

### B6 — why no "one live pass" rule

A partial unique index cannot express it: liveness is derived from the attempt (P4), so there is no
column to index, and adding one purely so an index can police the rule would reintroduce the stored
state P4 exists to avoid.

The rule is also not needed. Unlimited concurrent passes, consumed oldest-first, is deterministic,
lets an operator grant a corporate client three passes in one sitting, and cannot race on a
double-clicked invite button.

### B7 — why standings cannot reuse `place_of`

`GameRun#place_of` (`app/models/game_run.rb:143`) carries the warning directly:

> Scoped to THIS run. Game-scoped ranking compared absolute timestamps across every cohort that
> ever played, so a team playing months later always placed last however fast it was — the defect
> this whole programme exists to fix.

Commercial standings are cross-cohort by construction: every pass starts when its team opens the
play screen. So they rank on **duration**, a quantity this codebase has never needed, and share no
code with `place_of` or `effective_finished_at`. Both remain correct and untouched for scheduled
runs.

## 2. Data model

### 2.1 `games`

```ruby
add_column :games, :visibility,  :string, :default => "draft",     :null => false
add_column :games, :access_mode, :string, :default => "scheduled", :null => false
```

Backfill: `visibility = 'draft'` where `is_draft`, `'listed'` otherwise. `withdrawn_at` is **not**
consulted by the backfill and is not changed — it remains a separate, orthogonal fact (B2a). Every
existing game gets `access_mode = 'scheduled'`.

`is_draft` is dropped once every reader has moved. Fifteen files reference `is_draft` or `draft?`,
including both author forms (`games/new.html.erb:67`, `games/edit.html.erb:76`), the permit list
(`games_controller.rb:269`), `ensure_author_if_game_is_draft`, `SecurityFilters` (`:71`),
`GameRun#results_visible?` and `shared/_countdown.html.erb`.

**The author form keeps its checkbox.** Checked means `draft`, unchecked means `listed` — identical
UX, so no author has to learn a new control and no locale needs a new set of option labels. The
permit list takes `:visibility` in place of `:is_draft`, and the checkbox is bound with explicit
checked/unchecked values.

### 2.2 `access_passes`

| Column | |
|---|---|
| `game_id` | NOT NULL |
| `team_id` | NOT NULL |
| `source` | `operator_invite`; sub-project C adds `access_code` |
| `issued_by_id` | the operator or superadmin who issued it |
| `revoked_at` | nullable |
| `created_at` / `updated_at` | |

Index on `(game_id, team_id)`, non-unique — B6 permits several.

**`team_id` is NOT NULL and stays that way.** An unredeemed access code is *not* a pass: in
sub-project C it is a row in a separate `access_codes` table holding a digest, and redeeming it
*creates* a pass. C therefore adds a table rather than migrating this one.

### 2.3 `game_passings`

```ruby
add_column :game_passings, :access_pass_id,  :integer
add_column :game_passings, :paused_seconds,  :integer, :default => 0, :null => false
add_index  :game_passings, :access_pass_id, :unique => true, :where => "access_pass_id IS NOT NULL"
```

The partial unique index is the 1:1 binding that makes `AccessPass#spent?` derivable. It is written
explicitly rather than relying on the existing `(team_id, game_run_id)` index, which stops
constraining commercial rows only because SQL compares NULLs as distinct — true, but implicit, and
not something to leave a future reader to infer.

### 2.4 `logs`

```ruby
add_column :logs, :game_passing_id, :integer
add_index  :logs, :game_passing_id
```

Written by `GamePassingsController#save_log`, which already holds `@game_passing`. Backfilled from
`(game_run_id, team_id)` by a `Log.backfill_passing_ids!` modelled on the existing
`Log.backfill_run_ids!` — including its rule that the method reports its count, because a backfill
that resolved nothing must not look identical to one that resolved everything.

## 3. The entitlement

```ruby
class AccessPass < ApplicationRecord
  belongs_to :game
  belongs_to :team
  belongs_to :issued_by, :class_name => "User", :optional => true
  has_one    :attempt,   :class_name => "GamePassing", :foreign_key => "access_pass_id"

  def revoked?
    revoked_at.present?
  end

  def spent?
    attempt.present? && attempt.finished_at.present?
  end

  def live?
    !revoked? && !spent?
  end
end
```

**`spent?` reduces to one column, and the reduction is worth understanding before anyone
"corrects" it.** The programme design (P3) says a pass is spent when the TEAM ended the attempt —
by completing it, or by quitting — and not when an operator did. Those endings map onto
`game_passings` like this:

| Ending | `finished_at` | `status` |
|---|---|---|
| Team completed the course | set | nil (or `ended`, if the operator later closed the game) |
| Team quit (`exit!`) | **set** | `exited` |
| Operator closed the game (`end!`) | **nil** | `ended` |

`GamePassing#exit!` (`app/models/game_passing.rb:261`) sets `finished_at` as well as the status, so
"completed or exited" is exactly "`finished_at` is present" — and `end!` is precisely the case that
leaves it nil. One column separates team-caused endings from operator-caused ones, with no
reference to `status` at all.

The rule is still **"the team ended it"**; `finished_at.present?` is today's encoding of that rule,
not the rule itself. So the predicate carries a comment saying so, and its spec asserts all the
states in the table above — including both operator cases — so that a future change to what `end!`
writes fails a test instead of silently spending customers' passes.

Selecting which pass to consume is the same predicate negated, oldest first: the team's passes for
this game with `revoked_at` NULL and no attempt carrying a `finished_at`, ordered by `created_at`.
It is a scope on `AccessPass` rather than an ad-hoc query, because §4 and §8 both ask it.

## 4. Play-path resolution

`find_or_create_game_passing` branches on `access_mode`. Scheduled games are unchanged.

```
pass_required:
  in-progress attempt for this game?   -> serve it
  else oldest live pass?               -> create GamePassing(game_run_id: nil,
                                                             access_pass_id: pass.id,
                                                             current_level: game.levels.first)
  else                                 -> 401 errors.no_access_pass
```

"In-progress" means the team's attempt at this game whose pass is not spent. The existing rule that
**an existing passing is served before any gate runs** is preserved and is what lets a spent pass
keep its own finished attempt readable.

One case deserves spelling out, because it is the only one where an unspent pass already has an
attempt. When an operator closes a game, `end!` marks every attempt `ended` and leaves
`finished_at` nil — so those passes are NOT spent (P3: the operator ended it, the customer did
not) while the attempt still exists. The resolution above serves that same attempt rather than
creating a second one, which is correct: `unfinish!` and `reinstate!` are how such a game and its
attempts come back, and they resume where the team stopped. **A pass never yields two attempts.**

### 4.1 Filters that change

| Filter | Change |
|---|---|
| `ensure_game_is_started` (`:625`) | For `pass_required`, "started" is meaningless: it becomes "visibility is not `draft`". A draft commercial game must still refuse, or an operator's unfinished work is playable by anyone holding an invitation. |
| `ensure_team_not_exited` (`:713`) | **Unchanged** -- corrected 2026-08-18, whole-branch review finding 7. It looked like it would need to become "exited **and** no further live pass", so a team that bought a replacement is not locked out by a filter guarding the attempt they paid to replace. It does not need to: `find_or_create_game_passing`'s gated resolution (`gated_passing`, above) already hands back a NEW attempt when a live replacement pass exists, and raises `Authentication::Unauthorized` before this filter is ever reached when none does -- so an exited passing can only arrive here when the team truly has no further pass, which is exactly when refusing is correct. Task 6's review verified this by driving the controller, not by reading the code; only the comment on the filter itself was changed to record why, never the filter. |
| `ensure_not_author_of_the_game` | Unchanged. |
| `ensure_game_not_finished_by_author` | Unchanged — `author_finished?` delegates to the current run, which is how an operator retires a commercial game. |

### 4.2 `Game#resume!` — a real defect this design would otherwise introduce

`app/models/game.rb:209` shifts the hint clock of every unfinished passing when a pause ends:

```ruby
current_run.passings.where(:finished_at => nil).find_each { |gp| ... }
```

A runless attempt is not in `current_run.passings`. The *freeze* works — `GamePassing#effective_now`
reads `game.paused_at`, which delegates — but the *thaw* would skip commercial attempts, and every
hint on their current level would jump forward by the length of the pause. Nothing raises; the team
simply finds its hints spent.

It becomes:

```ruby
game_passings.in_progress.find_each do |gp|
  gp.update_column(:current_level_entered_at, gp.current_level_entered_at + held)
  gp.update_column(:paused_seconds, gp.paused_seconds + held.round)
end
```

Two changes. `game_passings` instead of `current_run.passings` is the runless fix. `in_progress`
instead of `where(finished_at: nil)` is a correctness fix to existing behaviour: `end!` sets status
`ended` **without** `finished_at`, so today a passing an operator has already closed still gets a
clock it does not have shifted. The `in_progress` scope already states the condition properly.

## 5. Duration and standings

```
duration = finished_at − created_at − paused_seconds + penalty_seconds
```

`created_at` is the attempt's start: the passing is created when the team first opens the play
screen, and `before_create :update_current_level_entered_at` already treats that instant as the
beginning.

Standings list **completed** attempts only — `finished_at` present and status not `exited` — one
row per attempt, ordered by duration ascending, shown on the game page when
`access_mode = pass_required`. A team appears as many times as it has completed passes, which is
B7's decision and matches what a pass is.

Operator interventions (`move_to_level!`, `reinstate!`) clear `finished_at`, so an intervened
attempt leaves the standings until it finishes again, and its duration then spans the intervention.
That is accepted rather than corrected: interventions are rare, operator-initiated, and already
understood to alter the record.

## 6. Run-scoped readers that need a second shape

The cost the programme design booked for B. Each is a reader that assumes a passing or a log has a
run:

- `LogsController` — `find_run` (`:109`), `count_the_run` (`:135`), and `show_full_log`'s join on
  `game_passings.game_run_id` (`:90`). Commercial logs address by `game_passing_id` (§2.4).
- `GamePassingsController#show_results` and `find_run`/`latest_started_run` — commercial results
  are per attempt, not per run.
- `GameRun#passing_for`, `#finished_teams`, `#place_of`, `#results_visible?` — untouched; they
  remain the scheduled-race path. Commercial standings are a separate method on `Game`.
- `GameEntry` — not used by commercial games at all. No entry is created; the pass is the
  admission.

Confirmed **not** to need changes, because they read passings directly rather than through a run:

- `Team#in_live_race?` (`app/models/team.rb:104`) — iterates `game_passings` and matches on
  `status.nil? && finished_at.nil?`. A runless commercial attempt counts automatically, which is
  what stops a captain reshuffling the team mid-paid-run. Ten call sites depend on this and none
  need editing.

## 7. Catalog, status, and sequencing

`Game#status` (`:345`) gains `:available`:

> withdrawn → draft → finished → **available** (when `pass_required`) → running → scheduled

`Game.count_by_status` (`:366`) gains the same bucket in SQL. **These two move together or neither
moves.** They are the two-definitions-of-one-idea pair the programme design names, and the file's
own comments record them disagreeing in production once already.

**Sequencing.** The visibility migration and the entitlement work fail differently — a bad
visibility migration leaks a draft to the public catalog; a bad entitlement change breaks one
team's play screen — so they are separate tasks with separate reviews, visibility first.

## 8. Operator surface, authority and audit

A controller for issuing and revoking passes, nested under the game, gated on
`User#may_operate_commercial?` (shipped inert by sub-project A) **and** `Game#pass_required?`.
Issuing takes a team by name; revoking is refused once the pass has an attempt (B11).

Both actions call `record_admin_action` — `issue_access_pass` / `revoke_access_pass` — with the
game as target and the team in `details`.

Two changes sub-project A deliberately deferred now land:

```ruby
# SecurityFilters#ensure_author -- A's spec §5 specified this line under the
# working name `commercial?`; the column landed as access_mode, so the
# predicate is Game#pass_required?.
return if logged_in? && current_user.operator? && @game&.pass_required?
```

```ruby
# AdminAudit#acting_as_operator? -- widen superadmin? to may_operate_commercial?,
# or an operator's acts on commercial games they did not author go unrecorded,
# which is precisely the population the role exists to create.
```

## 9. i18n

New keys in **all seven** locales (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`): the `:available`
status label, the standings column headers, the "you need a pass to play this" state on the game
page, the operator issue/revoke forms and their notices, the two audit-action labels, and
`errors.no_access_pass`.

Two project rules bind them. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a subset
check for the other five, so completeness in `uk`/`ka`/`be`/`pl`/`tr` is on the implementer, not on
a red build. And any key interpolating a team or game name must, in Turkish, put the case suffix on
a common noun rather than on the placeholder — the standings and invitation strings both carry
names, so this applies to them directly.

`spec/i18n_audit_actions_spec.rb` scrapes audit-action names out of the controllers and asserts a
translation in **every** available locale, so the two new audit labels are hard-covered.

## 10. Testing

- **Model** — `AccessPass#spent?` across all six states from the programme design's table
  (unstarted, in progress, completed, team-exited, operator-ended, operator-reinstated);
  oldest-first selection; duration arithmetic including a pause.
- **Request** — the play path for a gated game: no pass → 401; one live pass → attempt created with
  `game_run_id` NULL; second attempt after completing → consumes the second pass; exited with no
  further pass → refused; exited with a further pass → new attempt. Operator issue/revoke including
  the refusal on a started pass. Non-operator refusals.
- **Regression** — the scheduled path must be untouched: a run-scoped game still resolves through
  `current_run`, `place_of` still ranks within a run, and the inherited Cucumber contract (228
  scenarios / 2325 steps) still passes unchanged. That contract is the gate for "B did not bend the
  race path to fit the commercial one".
- **Pause** — the `resume!` fix needs an example with a runless attempt, since no existing example
  can fail on it.

## 11. Out of scope

Access codes, batches, digests and redemption (sub-project C). Points, ledgers, fines and the
global chart (sub-project D). Payment of any kind (programme §4). Multi-tenant separation between
operators. Solo play — commercial passes are held by teams, as scheduled runs are.
