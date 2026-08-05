# Superadmin reporting — stats and users

**Status:** approved 2026-08-05
**Extends sub-project A** (the superadmin role and the all-games console). Sub-projects B
(accountability) and C (live-game intervention) remain separate and unstarted.

## The problem

Sub-project A gave the operator a listing of every game with controls. It answers "what games exist
and what can I do to this one". It does not answer "how many games are there, in what states, and
who are these users" — the questions you ask when you want to know the shape of the instance rather
than act on one row of it.

Today those answers require `ssh` plus `psql`.

## Scope decision: a fixed screen, not a query interface

"Querying the database" has two readings and they are not the same feature.

A **fixed stats screen** answers a known set of questions with queries written in Ruby: reviewable,
testable, and incapable of becoming something else. A question nobody anticipated needs a code
change.

An **in-app SQL console** answers any question without a deploy. It was rejected. Read-only is hard
to enforce properly, it exposes every column of every table — including password hashes — to anyone
holding the role, and sub-project B exists specifically to make that role grantable to a helper. If
it is ever wanted it needs its own threat model, not a section in this spec.

The unrestricted option already exists and is retained: `ssh mezin` and `psql`. Anything built
in-app is strictly more exposed than that, never less.

## Privacy boundary

`users` holds `email`, `phone_number`, `jabber_id`, `icq_number` and `date_of_birth` — data players
supplied in order to play a game, not to be browsed — alongside `crypted_password` and `salt`.

**`crypted_password` and `salt` are never rendered anywhere, under any option.** A displayed hash is
not merely useless, it is an offline cracking target handed to anyone who can screenshot the page. A
spec asserts their absence; the risk is not that someone adds them deliberately but that a
future `<%= user.attributes %>` debugging line leaks them silently.

The rest is split deliberately:

| Screen | Shows |
|---|---|
| Users list | nickname, email, team, locale, signed-up date, superadmin flag |
| User detail | the above plus phone, Jabber, ICQ, date of birth, team history, games authored |

Nothing is hidden from the operator. But reading the whole membership's contact details takes
deliberate clicks rather than one glance. That costs nothing today and matters the moment
sub-project B allows this role to be granted to a helper — assume whatever this screen shows, a
helper eventually sees.

## The stats screen

`Admin::DashboardController#show`, at `/admin`, gated by `require_superadmin!` after
`require_authentication!` — the same order every other controller in this app uses.

### Games by status

Derived from the states the application already has. A game can be locked *and* running, so
"editing locked" is reported alongside the statuses rather than as one of them.

**Each game counts once**, under the first status that matches, in this order. The derivations
overlap by construction — a draft has no start time in the past, a withdrawn game may also be
finished — so a precedence is required or the columns will not sum to the total.

| # | Status | Derivation (given none above it matched) |
|---|---|---|
| 1 | Withdrawn | `withdrawn_at IS NOT NULL` |
| 2 | Draft | `is_draft` |
| 3 | Finished | `author_finished_at IS NOT NULL` |
| 4 | Running | `starts_at IS NOT NULL AND starts_at < now` |
| 5 | Scheduled | everything else — includes a game whose `starts_at` is `NULL` |

This order matches how sub-project A's console labels a game in its status column, deliberately: two
screens disagreeing about what a game *is* would be worse than either being wrong on its own.

`starts_at` is nullable and `Game#started?` already treats `NULL` as not started — the SQL must do
the same, which is why "Running" tests for `NOT NULL` explicitly rather than relying on a `NULL`
comparison evaluating false.

**Editing locked** (`editing_locked_at IS NOT NULL`) is reported separately, as a count alongside
the table rather than a row in it. A game can be locked *and* running, and forcing it into the
precedence above would hide one fact to show the other.

**The counts must sum to `Game.count`.** A spec asserts that, because it is the one property that
catches a mis-specified predicate without anyone having to reason about the precedence.

### Headline counts

Users, teams, games, game entries by state, and game passings split into finished and in progress.

### Every count is a SQL aggregate

Not `.select` in Ruby. The existing `Game.started` loads every game and filters in memory — correct
enough for a listing of two, wrong for a counter, and exactly the habit that makes an admin page the
slowest page on a site. This constraint is the reason the status derivations above are expressed as
column predicates rather than as calls to the existing predicate methods.

## The users screens

`Admin::UsersController#index` — the list above, sorted newest first.

`Admin::UsersController#show` — the detail above.

Both gated identically to the dashboard. No pagination and no search, for the same reason sub-project
A's console has none: the instance has a handful of users, and adding filtering before there is
anything to filter is how admin panels accumulate features nobody uses. When the list stops fitting
on a page, that is the moment to add it.

## Read-only, without exception

Every screen in this spec is a `GET`. No editing users, no granting or revoking the role, no
deleting anyone, nothing that writes. Granting the role is sub-project B; it is deliberately not
here, because a screen that both displays every user and can promote one of them is a much larger
security decision than a reporting screen.

## Testing

Weighted to authorization, as with sub-project A, and for the same reason: this codebase shipped
four unauthorized destructive `GamesController` actions through its last migration with 400-odd
specs green.

- Anonymous refused, ordinary signed-in user refused, superadmin admitted — on **all three** screens.
  Each asserted, not assumed.
- `crypted_password` and `salt` absent from every rendered response.
- Each status count correct against a fixture containing at least one game in every state, including
  a game that is both withdrawn and started, since the status derivations are not mutually exclusive
  by construction.
- **A query-count guard on the users list**, which renders a team per row. This exact N+1 has now
  been written into two consecutive plans in this project — the all-games console shipped one, found
  only when a reviewer instrumented it. It gets a test here rather than a comment, asserting the
  count stays flat as the number of users grows rather than pinning a magic number.

`features/**` is a read-only contract from the Merb port and is not touched. Coverage is RSpec.

## Rollout

No migration. No schema change of any kind — every figure is derived from columns that already
exist. Three new read-only controllers, their views, routes, and locale keys in all four files.

## Risks

1. **This is the first screen that aggregates personal data across all users.** It grants no access
   that `psql` did not already give the operator, but it makes that data *browsable*, which is a
   different thing. Sub-project B's audit trail becomes more valuable once this exists, not less.
2. **Counts computed in Ruby would degrade quietly.** The SQL-aggregate constraint is load-bearing,
   not stylistic; a reviewer should treat `.select`/`.count` on a loaded collection as a defect.
3. **`Game.started` and `Game.notstarted` remain in-memory selectors** and are used elsewhere in the
   app. This spec does not change them — it declines to build on them. Changing them is a separate
   decision with its own blast radius.

## Out of scope

- Any arbitrary-query or SQL-console interface.
- Editing, creating or deleting users; granting or revoking the superadmin role (sub-project B).
- Any control touching a running game's `GamePassing` records (sub-project C).
- Charts, time series, or export. Counts and lists only.
- Pagination and search, until the lists stop fitting on a page.
