# Commercial games — programme design

**Date:** 2026-08-18. **Decided by:** repository owner (`mezinster`), in session.

This document is the umbrella. It records the decomposition into four sub-projects, and the
decisions that cut across more than one of them. Each sub-project gets its own spec and its own
implementation plan; this file exists so that a decision reached while designing B is still findable
when C is built three weeks later.

## 0. What was asked for

A client wants to sell games as separate units. A customer buys a code; entering it registers their
team for one full pass through the game. Such games are quests or quizzes, appear in the public
games list when not drafts, and are created by a new role that superadmins can grant.
Holders of that role generate the codes and can also invite teams directly. Separately, a **points** system:
teams earn points for passing levels and finishing games, lose them to fines (skipping a level), and
a global chart shows what every team has played and earned.

**The role is called `operator` in code and «оператор» in the interface**, not "admin". The
client's word was "Admin", but `Admin::` is already this application's superadmin console namespace
and «администратор» is already the superadmin's user-facing label (`config/locales/ru.yml:28`). See
the sub-project A spec, D6.

**Selling is out of scope for this platform.** Nothing here takes payment, issues receipts or talks
to a payment processor. The platform *issues* codes and an operator distributes them by whatever
commercial channel they already have. Every use of "buy" or "purchase" below describes something
that happened outside this application.

## 1. Decomposition

Four subsystems, which arrived together in the request but are separable:

| | Sub-project | Content | Depends on |
|---|---|---|---|
| **A** | Operator role | `users.is_operator`, superadmin grants/revokes, audited | — |
| **B** | Access-gated games | `access_mode`, the entitlement model, the private attempt, play-path resolution. Proven end to end via **operator invitation only**. | A |
| **C** | Access codes | Batch generation, digest storage, one-time export, redemption form | B |
| **D** | Points | Append-only ledger, per-game scoring config, skip-level action, global chart | — |

**Order: A, then B, then C. D may run in parallel with any of them.**

**Why B before C.** The entitlement and the secret that creates one are separate concerns — the
client's own framing, and it is right. Building the entitlement first, with an operator clicking
"invite this team" instead of anyone typing a code, exercises the entire play path (private
attempt, resolution, expiry) with no code generation, digest storage or export UI in the way. The
hard part of this programme is §3 below; C adds nothing to it. If the play-path work goes badly,
that is discovered with four fewer moving parts in the diff.

**Why D is independent.** Points apply to ordinary scheduled games too (P6). An append-only ledger
and a chart touch almost nothing that already exists, and nothing in D needs to know that
commercial games exist.

## 2. Cross-cutting decisions

| # | Decision | Answer |
|---|---|---|
| P1 | Who may hold the operator role, and what does it reach? | **Globally assignable** by any superadmin — no per-game grant table. Authority is scoped to **commercial games only**: an operator may operate any commercial game on the instance, and has no special power over ordinary games they did not author. |
| P2 | May the same team play the same game twice? | **Yes, on a second pass.** Not to replay with the same people — the answers are known by then — but so one team account can buy another ticket and play with a different set of friends. The data model must allow N passes per `(team, game)` over time. |
| P3 | What spends a pass? | **Who ended the attempt decides who pays.** Completing the game spends it. The team quitting spends it. An operator ending the game or intervening does not. |
| P4 | How is "spent" stored? | **It is not stored.** It is derived from the attempt's state. Only `revoked_at` (refund, fraud) is a stored column. |
| P5 | What is a private commercial attempt, physically? | A `GamePassing` with **`game_run_id` NULL** and `access_pass_id` set. It is not a `GameRun`. |
| P6 | Are points commercial-only? | **No.** Points are a parallel currency across commercial and ordinary games alike. They do not interact with the existing time penalties. |

### P3 — why "who ended it" rather than a simpler rule

Two simpler rules were considered and rejected.

*Any terminal attempt spends the pass* is one predicate and no extra column, but it charges a
customer for a run they did not get whenever an operator closes a game early.

*Only completion spends it* is what "expires when the run is completed" literally means, but it
makes quitting a free rewind. Combined with D, that is a points farm: quit on the last level,
start again, re-collect every level award, repeat indefinitely on one purchase. The interaction is
only visible when B and D are considered together, which is why it is recorded here rather than in
either spec.

The chosen rule costs one nullable column recording who terminated the attempt, and one branch.

### P4 — why the state is derived

`pass.spent?` is a question about the attempt, so it is asked of the attempt:

```
spent?  :=  attempt exists AND attempt is terminal AND the team caused it
```

Concretely, `GamePassing`'s existing outcome scopes already say this. `app/models/game_passing.rb:108`:

```ruby
scope :completed,   -> { finished_at NOT NULL AND status IS NOT 'exited' }
scope :interrupted, -> { status = 'exited' OR (status = 'ended' AND finished_at IS NULL) }
```

`completed`, or `status = 'exited'`, spends the pass. `ended` with no `finished_at` — the operator
closed the game — does not.

Storing the state instead would need a hook on every path that terminates a passing, and would
create a second definition of a fact the passing already holds. This repository has been bitten by
exactly that shape twice: `Game#status` disagreeing with the `with_current_run` SQL join, and
`start_test` clearing `is_draft` so test games appeared as RUNNING on the public home page
(reported from production 2026-08-15, see the comment at `app/models/game.rb:99`).

Deriving it also disposes of a subtler bug. The owner's requirement was that operator interventions
un-expire a pass. With a stored flag *and* a rule that a live pass entitles a fresh attempt, an
operator who reinstates a dead attempt grants two runs for one purchase — the team resumes the old
passing and still holds a redeemable pass. Because the pass is bound 1:1 to its attempt and its
state is read from that attempt, `GamePassing#reinstate!` and `#move_to_level!`
(`app/models/game_passing.rb:283`, `:296`) — both of which already clear `finished_at` and `status`
— un-expire the pass for free, with no second attempt to redeem and no un-expire code path at all.

The cost is querying: "how many codes in this batch are still unused?" becomes a join rather than a
column read. Denormalise later if it hurts, as a cache with the derived form still authoritative.

**`spent?` and `revoked_at` are different questions.** Revocation is an operator act with no
counterpart in the attempt, so it cannot be derived and is stored.

### P5 — why a private attempt is not a `GameRun`

The obvious model — one `GameRun` per purchased pass — is wrong here, and the reason is a
delegation. `app/models/game.rb:43`:

```ruby
delegate :starts_at, :registration_deadline, :max_team_number,
         :requested_teams_number, :author_finished_at,
         :is_testing, :test_date, :test_token, :paused_at,   # and every writer
         :to => :current_run
```

`Game#status`, `#started?`, `#paused?`, `#author_finished?`, `#pause!`, `#finished_teams` and
`#place_of` all read through those delegations, and `Game#current_run` (`game.rb:179`) is
`runs.to_a.last` — the highest ordinal. So the moment one team redeemed a code, `game.starts_at`,
`game.paused_at` and `game.author_finished_at` **as seen by every visitor to the catalogue** would
become that one team's private schedule. `Game.count_by_status` and the home page read those.

A `game_runs.kind` column with both definitions of "current" filtered to `kind = 'scheduled'` would
work — the Ruby one at `game.rb:179` and the raw SQL `MAX(ordinal)` join at `game.rb:77`. It was
rejected on failure mode rather than on effort. Under that design a forgotten filter means a private
attempt hijacks the public catalogue: silent, wrong for everybody, found in production. Under P5 a
forgotten nullable branch means one team's log or result page is empty or raises: loud, wrong for
one team, found in test. Given that this repository has already shipped the first kind of bug twice
(§P4), a third filter that must be remembered is not worth the saved effort.

The consequence to accept: every run-scoped reader — `logs.game_run_id`, the results page, the
stats screens, `GameEntry.of(team, run)` — learns a second shape. That is roughly fifteen files of
small nullable branches, and it is B's main body of work. The existing unique index on
`game_passings (team_id, game_run_id)` also stops constraining commercial rows, because SQL compares
NULLs as distinct — which happens to be the replay behaviour P2 wants, but is implicit semantics and
gets an explicit partial index in B rather than trust.

### P6 — points do not extend the existing penalties

`levels.wrong_answer_penalty` and `game_passings.penalty_seconds` already exist. They are **time**
penalties, folded into `GamePassing#effective_finished_at` for ranking. Points are a second,
parallel currency and are not unified with them: a fine deducts points and does not move the clock.

## 3. What each sub-project spec still has to settle

Recorded here so nothing is silently dropped between specs.

**B** — the `visibility` / `access_mode` / `scoring_mode` vocabulary and which combinations are
legal; what `Game#status` reports for a game with no schedule; whether `ensure_game_is_started`
applies at all to a game that is never "started"; whether a team may hold two live passes for one
game simultaneously; whether redeeming requires being the team captain; how a run-scoped log and
results page address a runless attempt.

**C** — code format and entropy; digest algorithm; batch model and one-time export; what a
redemption attempt against an already-assigned code reports; rate limiting on the redemption form
(the app already has `RequestThrottling`).

**D** — the award and fine schedule and whether levels override the game default; whether a team may
skip a level into a negative balance; whether the ledger is visible to players or only in the chart;
what the chart ranks by.

## 4. Out of scope for the whole programme

Payment processing, refunds as a money operation, invoicing, per-operator revenue reporting, and any
multi-tenant separation between operators. P1 deliberately makes every operator able to operate every
commercial game; if the client later needs operators walled off from each other, that is a
per-game grant table and a migration with a safe default (grant every existing operator every
commercial game), not a redesign.
