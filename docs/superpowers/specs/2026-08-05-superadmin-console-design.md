# Superadmin — the role and the all-games console

**Status:** approved 2026-08-05
**Sub-project A of three.** B (accountability) and C (live-game intervention) get their own specs.

## The problem

`encounter-engine` has no concept of a role. Authorization is entirely per-object: `games.author_id`
plus a `User#author_of?(game)` predicate, enforced by an `ensure_author` filter that six controllers
share. There is no way for the person operating an instance to see a game they did not create, let
alone act on it.

## Scope: why this is one of three specs

The stated need covered three purposes at once. They are not one feature:

| Purpose | What it actually demands |
|---|---|
| Operating the instance | See everything; edit and delete. Trust total, population one or two. |
| Moderating others' content | The same, **plus** an audit trail and a way to grant the role without sharing a password. |
| Live-game rescue | Time-critical controls over a *running* race. Every intervention is itself a fairness event. |

The first two differ only in **trust**, which materialises as two concrete features — an audit log
and a granting UI — neither of which changes what the console *does*. The third is a different
animal: it acts on `GamePassing` records mid-race rather than `Game` records at rest, and
"correct a broken level while three teams are on it" has no safe generic answer.

All three share exactly one foundation: the role and a view listing every game. Hence:

- **A (this spec):** the role, the console, edit / withdraw / lock / delete.
- **B:** an audit trail of admin actions, and a UI to grant and revoke the role.
- **C:** live-game intervention, designed against real fairness constraints.

B and C both depend on A. Building A badly means they inherit it.

## The role

```ruby
# migration — additive, defaults false, no existing row touched
add_column :users, :is_superadmin, :boolean, default: false, null: false
```

```ruby
# app/models/user.rb — beside the existing captain? and author_of?
def superadmin?
  self.is_superadmin
end
```

Granting is a console one-liner until sub-project B builds the UI:

```ruby
User.find_by(email: "…").update!(is_superadmin: true)
```

### Why a column rather than an env-var list

An env var (`SUPERADMIN_EMAILS`) has one genuine advantage: an attacker with database write access
still could not grant themselves the role. It was rejected because it cannot be changed without a
redeploy, which makes sub-project B — a granting UI — impossible to build on top. A column is the
foundation B needs.

### Enforcement

One filter, already shared by six controllers:

```ruby
# app/controllers/concerns/security_filters.rb
def ensure_author
  return if current_user&.superadmin?
  raise Authentication::Unauthorized, t("errors.must_be_author") unless current_user&.author_of?(@game)
end
```

Widening the existing filter means a superadmin inherits authorship powers **everywhere they already
exist** — levels, hints, questions, game entries — without touching six controllers or growing a
parallel permission system that can drift out of sync with the real one.

**This makes `ensure_author` a security-relevant chokepoint.** It is a blanket grant: any future call
site silently admits superadmins too. That is the correct default here (an operator who can edit a
game can already edit its levels), but the filter carries a comment saying so, and a spec pins its
behaviour.

## The two locks

Two nullable timestamps on `games`, not booleans — the console should show *when*, which is what an
operator wants while investigating.

| Column | Meaning | Enforced at |
|---|---|---|
| `editing_locked_at` | The author can no longer modify the game or anything beneath it | `ensure_author` — refuses the author, still admits a superadmin |
| `withdrawn_at` | Hidden from the public list, refuses new teams | `Game.non_drafts`, `Game.notstarted`, and the `show` guard |

They are independent switches and may be applied together or separately.

Two boundaries worth stating, because both are guessable the wrong way:

- **`editing_locked_at` locks content and settings, not lifecycle.** The author cannot change the
  game, its levels, hints, questions or answers. A superadmin still can, and the existing
  lifecycle actions (`start_test`, `end_game`) remain available to a superadmin — a lock is for
  stopping an author changing things under investigation, not for freezing the operator's own
  ability to act.
- **A withdrawn game stays visible to its author and to a superadmin.** It disappears from the
  public listing and refuses new teams; it does not vanish from the author's own dashboard. A game
  silently disappearing from its creator's view, with no explanation, would generate a support
  question for every withdrawal.

### Withdrawal does not touch play in progress

A withdrawn game disappears from the listing and accepts no new teams. **Teams already mid-race
continue uninterrupted.** No player loses a race they were legitimately running.

For stopping a game dead, the application already has `end_game`, which ends every in-flight
`GamePassing`. A superadmin reaches for that separately. Building a second kill switch with
subtly different semantics would be worse than reusing the one that exists.

### Blast radius

Visibility currently funnels through four places: the `Game.non_drafts` scope, `Game.notstarted`, the `show` page's draft guard, and `ensure_author`. Both locks hook
into those. Nothing else in the codebase needs to learn about them.

## The console

A single controller, `Admin::GamesController#index`, gated by one `require_superadmin!` filter.

It lists every game with: name, author, primary locale, available locales, status, team count, and
both lock states. Status derives from what already exists — draft / scheduled / running / finished —
plus the locks. Default sort is most recently created, because "what just appeared on my instance"
is the operator's actual first question.

**No search, no filtering, no pagination.** The instance has a handful of games. Adding filtering
before there is anything to filter is how admin panels accumulate features nobody uses; it is easy
to add when the list stops fitting on a page.

**No separate editing UI.** Widening `ensure_author` means a superadmin follows the ordinary edit
links and gets the author's own forms. Less code, and no second subtly-different game editor to keep
in sync with the first.

## Deletion behaves by history

**Correction, verified against the running app after this spec was first written:** deleting a game
does *not* cascade. `db/schema.rb` declares **zero** foreign keys and `Game`'s associations carry
**no `dependent:` option**, so `@game.destroy` removes the game row and leaves every level, hint,
question, answer, log, game entry and game passing orphaned, still holding a `game_id` that now
points at nothing. Proven with a probe: the game row disappears, the level remains.

That makes the case for restricting deletion stronger rather than weaker, though for a different
reason than first assumed. The danger is not that players' history is erased — it is that the
history becomes unreachable garbage still occupying the tables, and that `Level#game` starts
returning `nil` for rows that code elsewhere assumes have a game.

It also means the supposedly-safe path is broken today: deleting an untouched draft orphans its
levels just the same. So permitting deletion at all requires making deletion clean up after itself.

The logs and game passings are, separately, not the author's content — they are **players'**
history: which teams played, when they finished, their placements.

| Situation | Behaviour |
|---|---|
| No `game_passings` at all | Delete, behind a confirmation naming the game — and delete the levels, hints, questions, answers and game entries with it, rather than orphaning them as today |
| Any team has played | **Refuse.** Offer withdrawal instead |

Cleaning up on delete is a change to the *existing* author-facing delete too. That is deliberate:
it is a latent bug this feature would otherwise build on, and leaving it would mean the console's
"safe" delete quietly creates the same garbage the author's does.

Withdrawal achieves the operator's real goal — nobody can find or join it — without destroying
player history. So the console's destructive control is withdrawal in every case that matters, and
deletion is offered only where it is safe.

If a played game genuinely must be erased one day — a legal request, say — that is a deliberate
console operation, not a button sitting on a page.

## Testing

Weighted toward authorization, because that is where this codebase has actually been bitten: the
Merb→Rails port shipped with four destructive `GamesController` actions unprotected while 400-odd
specs and 234 Cucumber scenarios all passed.

- A non-superadmin reaching the console gets `Unauthorized` — asserted, not assumed.
- A superadmin can edit another author's game; a plain user still cannot.
- `editing_locked_at` blocks the author and admits the superadmin.
- A withdrawn game disappears from **each of the four visibility choke points** — one example per
  point. A single missed choke point means a "withdrawn" game is still reachable by URL.
- In-flight `game_passings` on a withdrawn game keep working.
- Deletion refuses when any `game_passing` exists and succeeds when none does.

`features/**` is a read-only contract from the Merb port and must not be touched. Coverage is RSpec.

## Rollout

Additive: one boolean defaulting `false`, two nullable timestamps. No existing row is rewritten and
no behaviour changes until someone is granted the role from a console — so the migration can ship
well ahead of the feature being used.

## What A deliberately does not do

1. **No audit trail.** A superadmin's edit is indistinguishable from the author's in the database.
   That is sub-project B, and it is the reason not to grant the role to a helper until B exists.
2. **Widening `ensure_author` is a blanket grant.** Any future call site of that filter will admit
   superadmins too. Correct today; mitigated by a comment and a spec, not by narrowing.
3. **No live-game intervention.** Withdrawal closes the doors; it does not reach inside a running
   race. That is sub-project C.

## Out of scope

- The audit trail and the role-granting UI (sub-project B).
- Any control acting on a running game's `GamePassing` records (sub-project C).
- Per-permission granularity. There is one role, and it can do what an author can do, everywhere.
- Impersonation, or any "act as this user" mechanism.
