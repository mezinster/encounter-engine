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

### 4 · Team membership programme — six phases, `design/team-membership-programme`

- Spec: `docs/superpowers/specs/2026-08-08-team-membership-programme-design.md`
- Origin brief: PR [#38](https://github.com/mezinster/encounter-engine/pull/38),
  `docs/handoff/2026-08-08-captaincy-transfer-context.md`
- Owner decisions D1–D5 recorded in §2 of the spec, answered 2026-08-08.

**The problem:** a team's captain can never be changed, and you cannot leave a team, be
removed from one, or delete one. So a captain who simply stops logging in **bricks their
team permanently** — it can never register for a game, invite anyone, or quit a race it is
already in, and its members can never form another team.

Six phases, each a separate plan, branch and PR. **Phases are strictly ordered** — each
depends on the one before, as noted.

| # | Phase | Plan | Depends on |
|---|---|---|---|
| 1 | **Foundations** — `Team#set_captain!`, refuse a captain owned by another team, guard the captainless-team mailer crash, plus the missing `TeamsController#create` spec | `docs/superpowers/plans/2026-08-08-team-membership-phase-1-foundations.md` — **5 tasks**. **Merged: PR [#43](https://github.com/mezinster/encounter-engine/pull/43)** | — |
| 2 | **Reassign captaincy** — net-new `Admin::TeamsController` (the admin console had no team management at all) plus captain self-service handover | `docs/superpowers/plans/2026-08-08-team-membership-phase-2-captaincy-surfaces.md` — **5 tasks** (PR [#45](https://github.com/mezinster/encounter-engine/pull/45)). **Built: PR [#49](https://github.com/mezinster/encounter-engine/pull/49)** | 1 |
| 3 | **Superadmin moves a user between teams**, audited, refused for captains and mid-race at either end | `docs/superpowers/plans/2026-08-08-team-membership-phase-3-superadmin-moves.md` — **3 tasks**. **Built: PR [#50](https://github.com/mezinster/encounter-engine/pull/50)** | 2 |
| 4 | **Leaving a team** — `POST /teams/leave`; a solo captain may leave, emptying the team | `docs/superpowers/plans/2026-08-08-team-membership-phase-4-leaving.md` — **3 tasks**. **Built: PR [#51](https://github.com/mezinster/encounter-engine/pull/51)** | 2 |
| 5 | **Join requests** — new `TeamJoinRequest` model; cannot reuse `Invitation`, whose frozen validation points the wrong way | not yet written | 4 |
| 6 | **`actor_label` on `AdminAction`, then user deletion and anonymise** | not yet written | 2 |

Plans are written **just before each phase is built**, not all up front: phase 1's
foundations shape everything after them.

**A rule worth carrying into every remaining phase**, learned the same way twice: an
assertion placed after a `raise_error` or `assert_unauthorized` expectation **in the same
example** can never fail on its own, because RSpec stops at the first failure. Both phases
found one of their own security assertions decorative that way — the refusal fired, the
data damage went unexamined. Put the refusal signal and the property it protects in
**separate examples**, and mutate to prove the second one can fail.

**A second rule, from phase 3:** a mutation has to fail for the reason you predicted, not
merely fail. A malformed mutation produces red from a render or syntax error and proves
nothing while feeling like confirmation. And a *negative* assertion ("does not offer X")
written before the positive case exists passes vacuously — only its mutation gives it
meaning.

**A third rule, from phase 4:** a test that *constructs* an end state cannot prove the
system **reaches** it. Phase 4's first attempt at proving the captainless-team chain set
`captain_id` to nil directly, and kept passing when the leave action was mutated to leave a
dangling captain behind — coverage of one link, wearing the label of the chain. Rewritten
as a request spec walking invite → leave → accept, it fails under two independent
mutations. When the claim is "A makes B reachable", the test has to travel from A to B.

**Descope point if the week is short:** phases 1–3 alone already unbrick every abandoned
team, which was the original problem — as of phase 3 that point has been reached. Phase 4
adds the escape hatch for members of a team they no longer want to be in. Phases 4–5 carry the largest UI surface and the only
real risk to the frozen acceptance suite.

**Constraints every phase inherits** (§6 of the spec): eight frozen scenarios bound this
design, including that a captain must be a member of their own team, and that four mail
assertions resolve their recipient through `team.captain` — so who the captain is at
accept/reject time is observable in the acceptance suite. Note the line numbers in the #38
brief point at *scenario headers*, not the assertions a few lines below; cite scenarios by
name.

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
- ~~No restore runbook and no WAL retention policy~~ — done 2026-08-07.
  `docs/runbooks/restore.md`, the `Database` workflow, and `wal-g delete retain FULL 7`
  in the nightly script. Both a `latest` and a point-in-time restore were rehearsed
  into a scratch container and verified.
- **Nothing alerts if the nightly backup stops.** The systemd timer failing, or the
  script exiting non-zero, is silent — you would find out when you needed a restore.
  `journalctl -u encounter-engine-backup.service` is the only signal today.
