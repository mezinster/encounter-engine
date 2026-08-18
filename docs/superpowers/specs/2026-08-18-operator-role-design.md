# The operator role — design

**Date:** 2026-08-18. **Decided by:** repository owner (`mezinster`), in session.
**Sub-project A of** `docs/superpowers/specs/2026-08-18-commercial-games-programme-design.md`.

## 0. The gap

This application has exactly one privileged role and it is all-or-nothing.
`SecurityFilters#ensure_author` (`app/controllers/concerns/security_filters.rb:32`) opens with

```ruby
return if logged_in? && current_user.superadmin?
```

and its own comment calls that line a **SECURITY CHOKEPOINT**: the filter gates games, levels, hints,
questions and game entries, so a superadmin may edit every one of them on every game, and "any
FUTURE call site of `ensure_author` silently admits superadmins too."

The commercial programme needs somebody who can create and run commercial games without that reach —
without, in particular, being able to edit an ordinary player's public game or its levels. Nothing
between "author of this one game" and "may edit everything" exists today.

This spec adds that role and the ability to grant it. **It deliberately grants no authority yet**;
see D5.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | Who may grant the role, and is it per-game? | Any superadmin, to any user. **Globally assignable** — no per-game grant table. |
| D2 | What may an operator act on? | **Commercial games only** — any of them, regardless of author. No special power over ordinary games they did not author. |
| D3 | Does superadmin imply the role? | **No.** Two independent booleans and one composite predicate. |
| D4 | Is there a last-operator guard? | **No**, and the asymmetry with `last_superadmin?` is deliberate. |
| D5 | Does this sub-project grant any authority? | **No.** The role is inert until sub-project B exists to be scoped to. |
| D6 | What is it called? | `operator` in code, «оператор» in the interface. **Not** "admin". |
| D7 | Does the role open the `Admin::` console? | **No.** That console stays `require_superadmin!`. An operator's own screens arrive in B, outside the namespace. |

### D3 — why superadmin does not set `is_operator`

The alternative is to write `is_operator = true` whenever superadmin is granted. It fails in an
ugly, quiet way: revoking the operator role from a superadmin would appear to work, change nothing
observable (because every check also passes them on `superadmin?`), and leave a row whose two
columns disagree with what the screen shows.

Two orthogonal booleans, with one predicate that ORs them, has no such state.

### D4 — why there is no `last_operator?` guard

`User#last_superadmin?` (`app/models/user.rb:116`) exists because "the instance must never end up
with nobody able to administer it", and it is enforced twice — in `Admin::UsersController#revoke`
and again as a model validation (`user.rb:276`), the latter because a console mistake is the real
risk.

None of that transfers. A superadmin can always grant the operator role back, so an instance with
zero operators is inconvenient for an afternoon, not bricked. The symmetry with `is_superadmin`
invites copying the guard along with everything else; this entry exists to say the omission is a
decision.

### D5 — why the role is inert on arrival

D2 scopes operator authority to commercial games, and the authority clause therefore has to ask
`@game.commercial?` — a predicate that arrives in sub-project B. So A ships the column, the
predicates, the granting UI and the audit trail, and grants nothing.

That is the honest consequence of scoping the role narrowly instead of widening the chokepoint, and
it is preferable to the alternative. Folding A into B would put an inert-role migration, a console
screen and seven locale files into the same diff as the play-path surgery, which is the part that
needs the review attention.

Deploying A before B costs nothing, because the role does nothing. That is a release decision, not
a design one.

### D6 — why not "admin"

The client's word for this role is "Admin". It is taken, three times over:

* `Admin::` is the superadmin console namespace (`config/routes.rb:12`). `Admin::GamesController`
  requires superadmin, so `users.is_admin` would leave the namespace meaning the opposite of the
  column.
* `grant`/`revoke` on `Admin::UsersController` (`app/controllers/admin/users_controller.rb:28`,
  `:35`) already grant **superadmin**, and the helpers are `grant_admin_user_path` /
  `revoke_admin_user_path`. A second pair for the new role would read
  `grant_admin_admin_user_path`.
* «администратор» is already the superadmin's user-facing label —
  `admin.users.index.superadmin`, `admin.users.show.grant`, `errors.must_be_superadmin`, and both
  audit-action labels (`config/locales/ru.yml:30`, `:45`, `:85`, `:86`, `:231`).

The third point is cheap to change — **no spec and no feature file pins that Russian string** (both
suites grepped: zero hits) — but the first two are not, and the client's vocabulary is a UI concern
rather than a schema one.

`operator` is also the word this codebase already uses in prose for this exact capacity:
`AdminAudit#acting_as_operator?` (`app/controllers/concerns/admin_audit.rb:59`), the "Operator
interventions" comment (`app/models/game_passing.rb:278`), "an operator who can edit a game"
(`security_filters.rb`). One consequence to handle in §6: `acting_as_operator?` currently means "a
superadmin acting on someone else's game", and once the role exists, "operator" carries both that
capacity sense and a role sense. Its comment must say so.

## 2. Data model

```ruby
add_column :users, :is_operator, :boolean, :default => false, :null => false
```

No index, matching `is_superadmin`, which has none: the only aggregate over it
(`User.superadmin_count`) scans a table with a few thousand rows at most.

## 3. Predicates

On `User`, beside `superadmin?` (`user.rb:92`):

```ruby
def operator?
  self.is_operator
end

# The single question every commercial surface asks. Superadmins pass without
# holding the role -- see D3: the two columns stay independent and this is the
# only place they are combined.
def may_operate_commercial?
  superadmin? || operator?
end
```

Nothing in sub-project A calls `may_operate_commercial?`. It is defined here, with its spec
coverage, so that B has one predicate to reach for rather than inventing `superadmin? || operator?`
at each of its call sites.

## 4. Granting

Two member actions on `Admin::UsersController`, siblings of the existing `grant`/`revoke`, behind
the controller's existing `require_authentication!` + `require_superadmin!` filters:

```ruby
def grant_operator
  user = User.find(params[:id])
  user.update!(:is_operator => true)
  record_admin_action("grant_operator", user)
  redirect_to admin_user_path(user), :notice => t("admin.users.operator_granted_notice")
end

def revoke_operator
  user = User.find(params[:id])
  user.update!(:is_operator => false)
  record_admin_action("revoke_operator", user)
  redirect_to admin_user_path(user), :notice => t("admin.users.operator_revoked_notice")
end
```

Routes, beside the existing pair:

```ruby
resources :users, only: [ :index, :show ] do
  post "grant_operator",  on: :member
  post "revoke_operator", on: :member
end
```

**No self-revocation guard and no last-holder guard**, unlike `#revoke`. Both of that method's
guards protect against locking the instance out of administration; neither applies (D4). A
superadmin revoking their own operator role loses nothing they cannot restore, and `require_
superadmin!` means nobody else can reach the action.

`record_admin_action` is called **after** the change lands, matching the concern's rule that a
refused action must leave no entry (`admin_audit.rb:20`).

**Views.** `app/views/admin/users/index.html.erb:26` gains a second `<span class="tag">` for
operators beside the existing superadmin one; `show.html.erb:40` gains a second button pair,
mirroring the existing conditional.

## 5. The authority clause — specified here, implemented in B

Recorded so that B implements the shape this decision actually chose rather than the convenient one:

```ruby
def ensure_author
  return if logged_in? && current_user.superadmin?
  return if logged_in? && current_user.operator? && @game&.commercial?   # <-- added in B

  raise Authentication::Unauthorized, t("errors.must_be_author") unless logged_in? && current_user.author_of?(@game)
end
```

`operator?` rather than `may_operate_commercial?`, deliberately: the line above already returns for
superadmins, so the composite would be redundant here. §3's predicate is for B's own surfaces —
the pass console, the invitation form — where no such preceding line exists.

Two further properties of that line are load-bearing:

* **`@game&.commercial?`, not a bare `|| current_user.operator?`.** `ensure_author` gates levels,
  hints, questions and game entries as well as games. The game-conditional form is what stops an
  operator from reaching an ordinary player's public game *through* its levels controller — the
  path a blanket widening would open without appearing in any diff that mentions games.
* **Safe navigation.** `ensure_editing_not_locked` two methods below already writes `@game&.`, which
  is evidence that at least one call site reaches these filters with no game loaded.

## 6. Audit

`AdminAudit#acting_as_operator?` (`admin_audit.rb:59`) is today

```ruby
logged_in? && current_user.superadmin? && game.author_id != current_user.id
```

and decides whether an act on somebody else's game is recorded. **B must widen it to
`may_operate_commercial?`**, or an operator's acts on commercial games they did not author go
unrecorded — which is precisely the population this role exists to create.

It is not widened in A: no operator can act on anything yet, so widening it now would be untestable.
Its comment gains the D6 note distinguishing the capacity sense of "operator" from the role sense.

## 7. i18n

New keys, in **all seven** locale files (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`):

| Key | ru |
|---|---|
| `admin.users.operator_granted_notice` | «Права оператора выданы» |
| `admin.users.operator_revoked_notice` | «Права оператора отозваны» |
| `admin.users.index.operator` | «оператор» |
| `admin.users.show.grant_operator` | «Сделать оператором» |
| `admin.users.show.revoke_operator` | «Снять права оператора» |
| `admin.audit.index.action.grant_operator` | «Выдал права оператора» |
| `admin.audit.index.action.revoke_operator` | «Снял права оператора» |

Seven keys × seven files. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a subset for
the other five, so a partial rollout would not go red — which is the reason to state "all seven"
here. The five machine-translated locales (`uk`, `ka`, `be`, `pl`, `tr`) get the same treatment as
every other key: translated, structurally checked, and unreviewed by a speaker.

Nothing existing is renamed. «администратор» remains the superadmin's label (D6).

## 8. Testing

* **Model spec** — `operator?` reads the column; `may_operate_commercial?` is true for a superadmin
  who is not an operator, true for an operator who is not a superadmin, false for an ordinary user.
* **Request spec** — a superadmin can grant and revoke; an operator cannot grant (the role gives no
  console access); an ordinary user and a guest are refused; each successful action writes exactly
  one `AdminAction` with the expected `action` string. `spec/requests/admin_audit_spec.rb` gains the
  two entries in its "the explicitly superadmin actions" block. (Note: `grant_superadmin` and
  `revoke_superadmin` are not currently covered there. Adding coverage for them is out of scope
  here, but the gap is real and worth a follow-up.)
* **No Cucumber feature.** The admin console is covered by request specs throughout; adding a
  port-authored `.feature` for it would break with the established pattern for this surface, not
  follow it.
* **`bin/rails db:test:prepare`** after the migration, per the repo's standard flow.

## 9. Out of scope

Everything the role will eventually be able to do: commercial games, access passes, code batches,
invitations, points. `ensure_author` is **not** touched in this sub-project (§5), and
`acting_as_operator?` is **not** widened (§6). No per-game operator grants (programme §4).
