# Superadmin live-game intervention

**Status:** approved 2026-08-05
**Sub-project C of three.** A (the role and console) is complete and open as PR #9. B (the audit
trail and role granting) is complete on `feature/superadmin-accountability`. C builds on B.

## The problem

Between watching a running game and killing it, there is nothing.

An operator can already see everything: `GamePassings#index` lists every team, its current level and
its time at that level; `Logs#show_live_channel` shows every code anyone has typed. What they cannot
do is act on any of it. When a team is stuck at a location that has been fenced off for roadworks,
or a captain hits "Сойти с дистанции" by accident, or lightning stops the whole event for forty
minutes, the only lever is `end_game` — which ends it for all twenty teams at once.

The four situations this design handles, all of which have a real-world trigger:

| Situation | Today | C |
|---|---|---|
| Team physically cannot pass a level | End the game for everyone | Move that team to a level |
| Captain quit by accident | Irreversible; `ensure_team_not_exited` blocks every later request | Reinstate the team |
| A team's hint countdown is wrong | Nothing | Reset that team's level clock |
| Everyone must stop and resume later | End the game for everyone | Pause and resume |

## The principle the whole design rests on

**Every intervention is a named method on the model that leaves the record in a state ordinary
gameplay could also have produced.** No form writes a column directly.

A generic editor over `GamePassing` — one form, every field — would be smaller to build and would
handle situations nobody has thought of yet. It was considered and rejected. A raw form over
`current_level_id`, `finished_at` and `status` lets a tired operator at two in the morning produce a
row the model has no path to and the code has never seen: `finished_at` set with `status` nil, or a
`current_level` belonging to a different game. Every later request that touches such a row behaves
in a way no test covers.

Four named actions, each moving the record between states the model already understands, is the
whole point. The cost is that a fifth situation needs a fifth action rather than being improvised in
the field, and that is accepted.

## Where it lives

`GamePassings#index` (`/stats/index/:game_id`) is already the page an operator watches a running
game from. The controls go there — the page that answers "which team is stuck" is the page that
unsticks it. Diagnosing on one screen and acting on another is the wrong shape for something used
under time pressure.

The logic does not go there. A new `InterventionsController` holds all five actions; each renders
nothing and redirects back to the stats page with a notice. `app/views/game_passings/index.html.erb`
grows a controls column and a pause banner. `GamePassingsController` keeps its single trivial
action.

## The three team-scoped interventions

Methods on `GamePassing`:

**`move_to_level!(level)`** — refuses a level belonging to another game, then sets `current_level`,
clears `answered_questions`, resets `current_level_entered_at` to now, and clears `finished_at` and
`status`.

That last clause is load-bearing. A team standing on a level is by definition not finished, so
moving a finished or exited team back into play must un-finish it in the same operation. Leaving
`finished_at` set on a team that is visibly mid-level is exactly the contradictory row the principle
above exists to prevent. The rest mirrors `pass_level!`, which already clears answered questions and
stamps the entry time.

**`reinstate!`** — undoes an accidental exit: clears `finished_at`, clears `status`, and resets
`current_level_entered_at` to now.

The clock reset is not optional. `exit!` leaves `current_level_entered_at` untouched, so a team that
quit an hour ago carries an hour-old entry time; reinstating without the reset fires every hint on
that level the moment they reload — turning a rescue into a bigger unfairness than the one it was
meant to fix.

**`reset_level_clock!`** — sets `current_level_entered_at` to now. Refused for a finished team,
which has no live countdown to correct.

### What happens to history: nothing

No intervention touches a `Log` row. Logs store team and level as plain name strings and record what
was actually typed and when, so they already survive changes to the things they name. A moved team
keeps every answer it ever submitted; B's audit trail records who moved it and when. Those two
together are the complete account, and neither is editable through any UI.

Results are not annotated. Marking an assisted team in the standings was considered and rejected as
a feature nobody asked for: the audit log already answers "was this team helped, and by whom".

## Pause and resume

One nullable column, `games.paused_at`. `Game#paused?` is `paused_at.present?`. The state is durable
rather than in-memory, so a deploy or a crash mid-pause leaves the game paused and resume works
whenever someone reaches it.

### The frozen clock

`Hint#ready_to_show?(entered_at)` is a pure wall-clock delta — `Time.now - entered_at >= delay` —
and nothing is stored about how much of a countdown has elapsed. So a pause that only corrects the
arithmetic afterwards is not enough: `level_hint_updater.js` polls `get_current_level_tip`
continuously, and during a forty-minute hold every hint would appear on players' screens in real
time. Resuming would then hand back countdowns for hints they had already read.

Rather than blocking the poller, hint arithmetic reads an **effective now**:

```ruby
# GamePassing
def effective_now
  self.game&.paused_at || Time.now
end
```

`Hint#ready_to_show?` and `Hint#available_in` take it as a second argument defaulting to `Time.now`,
so no existing caller changes. The consequences follow for free: `hints_to_show` freezes,
`upcoming_hints` freezes, `get_current_level_tip` returns an unchanging state to every poll with no
knowledge of pausing at all, and `time_at_level` stops advancing on the stats page.

One concept produces four correct behaviours. The alternative — an `ensure_game_not_paused` filter
on the tip endpoint — would have to be remembered by every future code path that reads a hint, which
is the failure mode this project has already been bitten by twice.

### The two actions

```ruby
def pause!
  raise ArgumentError, "already paused" if self.paused?

  update_column(:paused_at, Time.now)
end

def resume!
  raise ArgumentError, "not paused" unless self.paused?

  transaction do
    held = Time.now - self.paused_at
    GamePassing.of_game(self).where(:finished_at => nil).find_each do |gp|
      gp.update_column(:current_level_entered_at, gp.current_level_entered_at + held)
    end
    update_column(:paused_at, nil)
  end
end
```

**`update_column`, not `update!`, and this is not a style preference.** A running game does not
pass its own validations: `game_starts_in_the_future` adds an error whenever `author_finished_at`
is nil and `starts_at` is in the past, which is true of every game currently being played
(verified against the model — a `Game` with `starts_at` an hour ago and no `author_finished_at`
reports `["Starts at Вы выбрали дату из прошлого. Так нельзя :-)"]`). `update!` would therefore
raise `RecordInvalid` on the exact games pause exists for, and `update` would fail silently — the
same trap that already makes `reserve_place_for_team!` stop enforcing `max_team_number` once a
game starts. Any future write to a live `Game` row faces this; `finish_game!` escapes it only
because setting `author_finished_at` disarms the validation in the same save.

`pause!` refuses a game that is already paused or not live. `resume!` refuses one that is not paused.

Shifting `current_level_entered_at` forward by the held duration is exactly equivalent to not
counting the paused interval, because that column is the only input to every countdown.

`where(:finished_at => nil)` excludes both finished and exited teams, neither of which has a running
clock. `update_column` is deliberate: this is a mechanical bulk shift, and running validations and
callbacks per row would buy nothing.

**The transaction is deliberate, and is the opposite call from B's audit write.** There, the log
write is kept out of the action's transaction so a logging failure cannot block an administrative
change. Here the shift *is* the operation: a half-applied resume would hand some teams their
countdown back and silently rob others, and nothing downstream could detect the difference. The rule
is not "always" or "never" — it is whether the write is the point or a record of it.

### What players see

The banner renders above the current level, which they keep seeing. They have already read that
level, so hiding it protects nothing, and a team standing at a location in the rain should be able
to see what they were working on. The notice is what stops them wondering whether the site is
broken.

`post_answer` and `exit_game` are refused while paused — with a flash notice re-rendering the level,
**not** an `Authentication::Unauthorized`. A paused game is a normal temporary state, not an
authorization failure, and rendering it as one would be both confusing and untrue.

No free-text pause reason. It would be the most useful thing for real players and is still omitted:
it adds a column, a form field and an author-content rendering path (verbatim, never through `t()`)
to an action whose value depends on being one click under pressure.

## Authorization

The author intervenes in their own game; a superadmin intervenes in any.

The author is the person actually running the event and the only one who knows the location is
flooded. Routing every stuck team through the instance owner turns each one into a support
escalation at whatever hour the game runs.

This needs **no new authorization concept**. `ensure_author` already means "the author, or any
superadmin" — sub-project A widened it. So `InterventionsController` is:

```ruby
before_action :require_authentication!
before_action :find_game
before_action :ensure_author
before_action :ensure_editing_not_locked
before_action :ensure_game_is_live
```

`ensure_editing_not_locked` (also from A) already exempts superadmins, which gives the intended
behaviour for free: **an editing lock blocks the author from intervening but not a superadmin.** A
superadmin locks a game to stop the author touching it during an investigation, and letting the
author move teams around would defeat exactly that.

`ensure_game_is_live` is new and small: interventions are refused on a game that has not started, is
a draft, is withdrawn, or has been finished by its author.

Two cases the filter must explicitly allow, because getting either wrong makes an action
unreachable rather than merely wrong:

- **A paused game is live for this filter's purposes.** If `paused?` counted as not-live, `resume`
  would be gated behind a condition only `resume` itself can clear — a guard no request can ever
  satisfy. Sub-project B shipped exactly this defect (a last-superadmin branch that a prior guard
  always intercepted first), and its test passed while proving nothing. Every intervention stays
  available while paused; that is the point of pausing.
- **A game in test mode is live.** `is_testing` games skip `ensure_game_is_started` throughout
  `GamePassingsController`, and an author testing their own game is precisely who needs to try
  moving a team between levels. `ensure_game_is_live` follows the same exemption.

## Audit

Every action calls B's `record_admin_action` after the change lands, under B's established rule —
recorded when a superadmin acts on someone else's game, silent when an author acts on their own.
Action strings: `move_team`, `reinstate_team`, `reset_clock`, `pause`, `resume`.

**C adds one nullable `details` string column to `admin_actions`.** `AdminAction` carries a single
target, so a team-scoped intervention can name the game or the team but not both; `details` holds
the team name alongside a `Game` target. B is unmerged and ours, so this is a one-line additive
migration rather than a workaround built on top of a schema we could simply extend. `details` is
nil for every existing action and rendered only when present.

## Testing

Weighted to what would be worst if wrong.

- **The shift arithmetic.** Pause, advance the clock, resume, and assert a team's remaining
  countdown is unchanged. This is the one piece of real arithmetic in C and the one a future
  refactor is most likely to break silently.
- **Hints genuinely frozen during the pause,** not merely uncounted afterwards — assert
  `hints_to_show` does not grow while paused, since this is the failure the effective-now design
  exists to prevent and it is invisible in any test that only checks state after resuming.
- **Each intervention leaves a producible state:** `move_to_level!` on a finished team clears
  `finished_at` and `status`; `reinstate!` resets the entry clock; neither leaves a row ordinary
  gameplay could not have reached.
- **`move_to_level!` rejects a level from another game.**
- **Every intervention, including `resume`, is reachable on a paused game** — the guard that would
  make `resume` unreachable is cheap to write and its absence is invisible without a test that
  drives resume through the controller rather than calling the model directly.
- **A player cannot submit an answer while paused,** and gets the notice rather than a 401.
- **The authorization matrix**, asserted with specific statuses, never `not_to have_http_status(:ok)`:
  author on own game allowed; a different author refused; superadmin on any game allowed; a locked
  game refusing the author but not the superadmin; a game that is not live refusing everyone.
- **Audit rows** for a superadmin acting on someone else's game, and no row for an author acting on
  their own.

`features/**` is a read-only contract from the Merb port and is not touched. Coverage is RSpec.

## Rollout

Two additive migrations: `games.paused_at` and `admin_actions.details`. No existing column or row is
altered. A game with `paused_at` nil behaves exactly as today, which is every game that exists.

## Risks

1. **`resume!` is the only bulk write in the system.** A game with many teams does one `UPDATE` per
   unfinished passing inside a transaction. At this instance's scale (tens of teams) that is
   nothing; it is recorded here so that a future instance running hundreds of teams knows where to
   look first.
2. **A game left paused indefinitely** stops play for everyone with no automatic recovery. Deliberate
   — an automatic resume after a timeout would restart a game whose operator is dealing with the
   emergency that caused the pause. The paused state is visible on the admin games console.
3. **`update_column` in `resume!` bypasses validations,** which is correct for a mechanical shift but
   means a future validation on `current_level_entered_at` would not be enforced there.
4. **The author's blast radius grows.** Every author can now edit live state for their own players.
   The audit trail makes it visible rather than preventing it — the same trade B made for the
   self-propagating role.

## Out of scope

- Editing or deleting `Log` rows, or annotating results to mark assisted teams.
- A generic `GamePassing` state editor, or any form that writes a column directly.
- A free-text pause reason, and any player-facing notification beyond the banner.
- Automatic or scheduled pause and resume.
- Fixing the pre-existing bug where `exit!` sets `finished_at`, so a team that quits appears among
  `finished_teams` and receives a place in the standings. Real, unrelated to C, and folding a
  standings fix into an intervention feature would make both harder to review. It wants its own
  ticket.
- Anything touching the role, the console, or the audit trail beyond the additive `details` column.
