# Work queue

What is written but not yet landed, in the order it makes sense to take it.
Updated 2026-08-06.

Every plan here was written against a baseline that has since moved — `master`
is at **730 rspec examples / 0 failures / 6 pending** and **234 cucumber
scenarios (2 pre-existing "undefined") / 2362 steps**. **Re-measure at branch
time** rather than trusting a number written into a plan.

---

## In review — nothing to do but merge

| PR | Branch | What |
|---|---|---|
| [#19](https://github.com/mezinster/encounter-engine/pull/19) | `design/redundant-codes` | Per-level "any code passes" rule, **plus a cross-tenant authorization fix across five controllers**. Was stacked on #18; retargets to `master` now that #18 has merged. |
| [#20](https://github.com/mezinster/encounter-engine/pull/20) | `fix/game-entry-team-scoping` | Scopes game-entry actions to the captain's **own** team. Closes two holes: acting on another team's entry, and registering another team for a game. |

Both are green and reviewed. #19 carries three deferred minors listed in its
own description; they belong to that branch, not to any plan below.

---

## Planned, not started

### 1 · Per-user timezone — `design/per-user-timezone`

- Spec: `docs/superpowers/specs/2026-08-06-per-user-timezone-design.md`
- Plan: `docs/superpowers/plans/2026-08-06-per-user-timezone.md` — **5 tasks**

Each user picks a timezone; timestamps render in it, falling back to the
instance default so anyone who never chooses one sees exactly what they see
today. Tasks 4 and 5 are unrelated carried-forward bug fixes folded in at the
owner's request:

- **Task 4** — `Game#can_request?` computes the team-cap check, discards it, and
  returns a stray `Game.all.select` (always truthy). The cap is enforced only by
  the view that hides the registration link, so a direct GET registers past it.
- **Task 5** — the quiz form re-renders questions the team has already answered,
  so resubmitting charges the wrong-answer penalty a second time for a question
  they already got right.

The binding constraint is that four frozen features assert exact wall-clock
strings, so a user with no timezone must render **byte-identically** to today.

### 2 · The games listing — `design/profiles-and-games-list`

- Spec: `docs/superpowers/specs/2026-08-06-profiles-and-games-list-design.md`
- Plan: `docs/superpowers/plans/2026-08-06-games-listing.md` — **3 tasks**

`/games` currently shows a name and a row of links. Adds status, start, end and
participant counts. Confirmed unimplemented on `master`:
`app/views/games/_list.html.erb` is still the bare `<ul>` and `Game#status` does
not exist.

Three things worth knowing before starting it:

- **The plan's stated baseline (711) is stale.** Re-measure.
- **It extracts `Game#status`**, which changes the *admin* games screen as a side
  effect of building a public one. That precedence currently exists twice — in
  SQL in `Game.count_by_status` and as an `if/elsif` chain in
  `app/views/admin/games/index.html.erb` — with a comment explaining the two must
  agree. The plan replaces the comment with a method and a spec.
- **`games/_list` is rendered from two places** — `games/index.html.erb` and
  `dashboard/_my_games.html.erb` — so the team counts load in a helper, not a
  controller ivar, or the dashboard renders with them nil.

May conflict lightly with #19 on `config/locales/*`.

### 3 · Profile contacts — `design/profiles-and-games-list`

- Spec: same document as above
- Plan: `docs/superpowers/plans/2026-08-06-profile-contacts.md` — **3 tasks**

Retires the dead `icq_number` and `jabber_id` fields for Instagram, Telegram and
five messenger-availability flags.

**This one carries an authorised exception to the read-only-features rule.** Four
scenarios in `features/games/user-profile-view-and-edit.feature` type into and
assert those two fields, so removing them requires amending that file — granted
explicitly by the repository owner on 2026-08-06, and to be recorded in
`CLAUDE.md` in the same commit. It is the only feature file that work may touch.

Ordering: additive first, subtractive last. Dropping the columns before the
views stop reading them raises `NoMethodError` on the profile page, so the
obvious "migration first" ordering leaves the suite red for two tasks.

---

## Known, unfixed, no plan yet

- **`Question` has no renderable text**, so a multi-question quiz level gives the
  player nothing to tell its questions apart. Needs a schema column, authoring
  UI, and a decision on whether that text is translatable — a design pass, not a
  fix.
- **Multiple codes still mean "find all of them."** PR #19 makes that a per-level
  choice; it does not change what the *existing* `#88` mechanic means. If the
  intent is ever to retire that mechanic entirely, that is a separate decision
  requiring a third frozen-feature exception.
- **Branch protection on `master`** — several PRs have merged with an empty
  `reviewDecision`.
- **No restore runbook and no WAL retention policy** for the production database.
