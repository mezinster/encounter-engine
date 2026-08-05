# Superadmin accountability — audit trail and role granting

**Status:** approved 2026-08-05
**Sub-project B of three.** A (the role and console) is complete. C (live-game intervention) remains
unstarted and undesigned.

## The problem

Sub-project A made an operator powerful and left them anonymous.

A superadmin can edit, delete, withdraw, lock, end and test-run any game on the instance. When they
edit someone else's game the database records an ordinary author edit: `games.updated_at` moves and
nothing says who moved it. There is no way to answer "who changed this, and when" — which is the
question you ask after something goes wrong, and the reason not to hand the role to anyone else.

The role is also console-only. Granting it means `psql` or `rails runner`, which for a helper means
either giving them the server or doing it for them each time.

These two gaps are why A's spec says plainly: *do not grant this role to a helper until B exists.*

## Scope

Two features, one spec. They are technically independent — the audit trail would work with no
granting UI, and vice versa — but granting is meaningless without the audit. The whole argument for
delegation being safe is that a delegated action leaves a trace. Splitting them would ship the
risk before the mitigation.

## What is audited: writes only

Every action that **changes data** while acting as a superadmin. Nothing else.

| Category | Actions |
|---|---|
| Explicitly superadmin | `withdraw`, `restore`, `lock`, `unlock` |
| Inherited via `ensure_author`, **only when the actor is not the author** | `update`, `delete`, `end_game`, `start_test`, `finish_test` |
| Role changes | `grant_superadmin`, `revoke_superadmin` |

`edit` is deliberately absent: it is a `GET` that renders a form and changes nothing. The write it
leads to is `update`, which is recorded.

**Reads are not audited**, including views of a user's contact details. That was considered and
rejected: every page view becomes a row, the log needs a retention policy, and routine support work
drowns the one entry anyone will ever want to find. The consequence is accepted and stated here so
it is not discovered later — this design answers "who changed this" and does not answer "who looked
at this player's phone number".

**Actions by an author on their own game are not audited.** An author editing their own game is
ordinary use, not an administrative act, and recording it would bury the administrative ones. The
condition is therefore "actor is a superadmin **and** not the game's author", not "actor is a
superadmin".

## The table

```ruby
create_table :admin_actions do |t|
  t.integer  :actor_id,    null: false
  t.string   :action,      null: false
  t.string   :target_type
  t.integer  :target_id
  t.string   :target_label
  t.datetime :created_at,  null: false
end
add_index :admin_actions, :created_at
add_index :admin_actions, :actor_id
```

`target_type` and `target_id` are nullable because not every action has a target.

### Why `target_label` exists

It stores the game's or user's name **as it was at the moment of the action**.

This is the load-bearing column. The single most important entry any audit trail will ever hold is
"who deleted what" — and a deleted game leaves `target_id` pointing at a row that no longer exists.
Without a snapshot of the name, that entry renders as `Game #47`: a number nobody can resolve,
recording the loss of the very thing that would have explained it. Snapshotting the label at write
time is the difference between an audit trail and a list of orphaned integers.

The same applies, less dramatically, to renames: an entry should say what the game was called when
it was withdrawn, not what it is called now.

### Append-only

Rows are never updated and never deleted. There is no UI to edit or remove an entry, and none should
be added. A log its own subject can edit is not a log.

No retention policy is specified because none is needed at this volume: a handful of administrative
actions a month, one short row each. If that ever changes, deciding a retention period is a smaller
problem than having no record at all.

## How it is recorded

An `AdminAudit` controller concern exposing one method:

```ruby
record_admin_action(action, target = nil)
```

It captures `current_user` as the actor, derives `target_type`/`target_id` from the target, and
snapshots `target_label` from the target's `name` (games, teams) or `nickname` (users).

**Called explicitly at each site.** An `around_action` that logged automatically was considered and
rejected. A filter that decides what is auditable by inspecting the request is precisely the
construct that silently stops covering a newly added action — the same failure this project already
hit, when splitting the editing lock out of `ensure_author` quietly narrowed it from six actions to
three and left `finish_test` able to erase player history. An explicit call is visible in the diff
of any new action; a clever filter is not.

The cost is honest and accepted: someone adding a superadmin action can forget the call. A spec
enumerating the audited actions is the mitigation, and it must be updated deliberately when the set
changes — which is the point.

### Recorded after the action succeeds, never before

`record_admin_action` is called only once the change has actually been made. A refused deletion, a
withdrawal that failed validation, an update rejected by the translation-completeness gate — none
of these leave an entry, because none of them changed anything.

This matters more than it sounds. An audit trail that records *attempts* answers a different
question from one that records *changes*, and mixing the two makes it useless for both: a reader
investigating "who deleted this" would find an entry for a deletion that never happened, and could
not tell from the log which entries were real. If attempted-but-refused actions are ever wanted,
they belong in a separate column or a separate table, deliberately.

The audit write is **not** wrapped in a transaction with the action. If the log write fails, the
action still stands — an operator being unable to withdraw a game because the audit table is
unavailable is a worse outcome than a missing row, and the failure will surface in the logs. This
is a deliberate choice against durability of the record, appropriate because the actions here are
administrative rather than financial.

## Granting

`Admin::UsersController` gains `grant` and `revoke` POST members, gated by `require_superadmin!`.

One flat role: anyone holding it can promote or demote anyone else. Two guards:

- **You cannot revoke your own role.** Prevents the accidental self-lockout, and means every
  demotion has a second party recorded in the log.
- **The last superadmin cannot be revoked.** Enforced in the model, so the instance can never reach
  a state where nobody can administer it — including through a console mistake.

Both grants and revocations are audited.

### The accepted risk

The role is self-propagating: a compromised superadmin account can create more superadmins. A
distinct owner tier would contain that, and was rejected as disproportionate — it introduces a
second role concept into a codebase that had none at all a week ago, with its own filters and its
own bootstrap question about who the owner is and how that ever changes.

The audit trail is what makes propagation **detectable** rather than invisible. That is the trade,
and it is the reason these two features ship together.

## Reading the log

`Admin::AuditController#index` — every entry, newest first: when, who, what action, which target.
Linked from the admin dashboard.

No filtering, no search, no pagination, for the same reason the rest of sub-project A has none: the
volume does not warrant it, and adding filtering before there is anything to filter is how admin
panels accumulate features nobody uses.

The actor renders as a link to that user's detail page; the target renders as `target_label`, linked
to the game only when the game still exists.

## Testing

Weighted to the two things that would make this feature worthless if wrong.

- **Every audited action writes exactly one row**, with the right actor, action and target — one
  example per action in the table above. This is the enumeration that substitutes for an automatic
  filter, so it must be complete.
- **An author acting on their own game writes no row.** The condition is "superadmin and not the
  author"; getting it wrong in the other direction floods the log with ordinary use.
- **`target_label` survives deletion** — delete a game, then assert the entry still names it. This
  is the property the column exists for and the one a future refactor is most likely to break.
- **The two granting guards**: revoking yourself is refused; revoking the last superadmin is refused.
- **Authorization** on all three new endpoints — anonymous, ordinary signed-in user, superadmin —
  asserted with the specific status, not `not_to have_http_status(:ok)`.

`features/**` is a read-only contract from the Merb port and is not touched. Coverage is RSpec.

## Rollout

One additive migration creating `admin_actions`. No existing table or row is altered. Nothing
changes for authors or players; every new screen and action is superadmin-only.

## Risks

1. **An action added later without an audit call goes unrecorded.** Inherent to the explicit-call
   design, accepted as the lesser evil against a filter that silently stops covering things. The
   enumerating spec is the guard.
2. **The self-propagating role.** Detectable, not prevented. If the instance ever has helpers who
   are not fully trusted, that is the moment to revisit the owner tier.
3. **`target_label` can go stale relative to a renamed target.** That is intended — it records what
   the thing was called at the time — but a reader comparing the log against a renamed game may be
   briefly confused.

## Out of scope

- Auditing reads of any kind, including personal data.
- Auditing actions by authors on their own games.
- A distinct owner or any second administrative tier.
- Editing, deleting or exporting audit entries.
- Filtering, search or pagination on the audit log.
- Anything touching a running game's `GamePassing` records — that is sub-project C.
