# Team Membership Phase 6 — Deletion and Anonymisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin remove a user account — permanently for housekeeping, or by scrubbing identity while keeping the row — without breaking the audit trail, stranding the instance, or bricking a team.

**Spec:** `docs/superpowers/specs/2026-08-08-team-membership-programme-design.md` — F4, S5, S6, decision **D4** (both operations, separately).

**Depends on:** phase 2 (captaincy reassignment, which both refusals point at).

## Global Constraints

- **Never edit `features/**/*.feature`.**
- `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` before every command.
- i18n keys in **all four** locales, **inside the existing block**.
- Hash rockets; plain fixture helpers, **no FactoryBot**.
- **No Turbo, no rails-ujs** — mutating controls are real forms.
- **Baselines as of this branch:** RSpec **1079 / 0 / 6 pending**, Cucumber **232 / 2342 / 0**.
- **Refusal signal and protected property in SEPARATE examples.**
- **A mutation must fail for the predicted reason** — and **check it took effect**: `db:create` loads `schema.rb`, so editing a migration file changes nothing.

## What the design missed, found while exploring

The design names two hazards of deletion: the audit trail (`admin_actions.actor_id`) and authored games. **Three more tables reference users and would be left dangling**, and `User` declares no `dependent:` option at all:

| Table | Column | Consequence |
|---|---|---|
| `invitations` | `for_user_id` | A pending invitation to a deleted user; `Invitation#find_user` and every listing dereference it |
| `team_join_requests` | `user_id` (`null: false`) | The captain's inbox renders `join_request.user.nickname` → `NoMethodError` |
| `game_locale_preferences` | `user_id` (`null: false`) | Orphan rows, harmless but permanent |

Task 2 handles these. Without it, phase 5's inbox 500s the moment an applicant is deleted.

## The two operations, and why both exist

|  | Hard delete (S5) | Anonymise (S6) |
|---|---|---|
| Row | Gone | Kept, identity scrubbed |
| Authored games | **Refused** — orphaning them 500s `games/show.html.erb:14`, which dereferences `@game.author.nickname` unguarded | **Allowed** — the row survives, so the author renders as the placeholder |
| Captain | Refused, pointing at reassignment | Refused, same reason |
| Last superadmin | Refused | Refused |
| Audit history | Survives via `actor_label` (Task 1) | Survives intact |

That authored-games row is the whole reason D4 asked for both.

---

### Task 1 — F4: `actor_label` on `AdminAction`

`admin_actions.actor_id` is `null: false` in the schema but `belongs_to :actor, optional: true` in the model, and the audit view already renders «неизвестно» when the actor is missing. Deleting an operator therefore turns every action they ever took into an unattributable row — in a log documented as append-only. `target_label` already exists for exactly this hazard on the other side; there is no actor equivalent.

**Files:** migration + backfill, `app/models/admin_action.rb`, `app/controllers/concerns/admin_audit.rb`, `app/views/admin/audit/index.html.erb`, `spec/requests/admin_audit_spec.rb`.

- [ ] Failing spec: a recorded action stores the actor's nickname in `actor_label`; the audit screen shows that label when the actor row is gone, instead of «неизвестно».
- [ ] Migration adding `actor_label` (nullable string) **and backfilling it** from existing actors in the same `up`, mirroring `20260808062600_backfill_log_team_and_level_ids`. Then `db:migrate` and `db:test:prepare`.
- [ ] `record_admin_action` writes `:actor_label => current_user&.nickname`; the view prefers the live actor (a link) and falls back to the label before «неизвестно».
- [ ] Mutate: stop writing `actor_label` → the storage example fails; make the view ignore it → the deleted-actor example fails.
- [ ] Commit.

---

### Task 2 — Stop deletion orphaning three tables

**Files:** `app/models/user.rb`, `spec/models/user/dependents_spec.rb`.

- [ ] Failing spec: destroying a user removes their invitations, join requests and locale preferences, and leaves **no** row anywhere still pointing at them. Assert per table, not in aggregate, so a partial fix cannot pass.
- [ ] Add `has_many :invitations, :class_name => "Invitation", :foreign_key => "for_user_id", :dependent => :destroy`, plus `:team_join_requests` and `:game_locale_preferences`, each `:dependent => :destroy`. Record in a comment that `created_games` deliberately has **no** `dependent:` — deletion refuses instead, because those are other people's games.
- [ ] Mutate each `dependent:` away in turn; each must fail its own example.
- [ ] Commit.

---

### Task 3 — S5: hard delete

**Route:** `delete "destroy", on: :member` in the admin users resource (a real DELETE; the control is a `button_to`).

**Refusals**, each before anything changes, each with the data property in its own example:

1. **Self** — an operator deleting themselves mid-session; mirrors `cannot_revoke_self`.
2. **Captain** — points at reassignment.
3. **Last superadmin** — mirror `last_superadmin_keeps_the_role`, which guards *revoking* and is bypassed entirely by `destroy`.
4. **Has authored games** — games are content other people played.

Audited as `delete_user`, with `AdminAction.label_for` capturing the nickname before the row goes.

- [ ] Failing request spec → route → action → locales → run → mutate all four → commit.

---

### Task 4 — S6: anonymise

**Route:** `post "anonymise", on: :member`.

Scrubs `email`, `nickname`, `phone_number`, `instagram`, `telegram_id`, `date_of_birth`, clears the messenger booleans, detaches from the team, and revokes superadmin. Placeholders must be unique: `"удалённый-#{id}"` and `"deleted-#{id}@example.invalid"`, since both columns are validated unique.

Refuses **self**, **captain** and **last superadmin** — but **not** authored games, which is the point of having both operations.

- [ ] Failing request spec, including one asserting an authored game still renders (`get game_path(game)` returns 200 after anonymising its author) — the property that distinguishes this from delete.
- [ ] Action, locales, run, mutations, commit.

---

### Task 5 — Verification and PR

- [ ] Rebase, `bin/rails db:test:prepare`, full `rspec` and `cucumber`, `git diff origin/master --stat -- features/` empty.
- [ ] Update `docs/superpowers/queue.md` — this completes the programme; say so.
- [ ] Push, `gh pr create --body-file`.
