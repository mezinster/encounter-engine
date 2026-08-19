# Operator adjustments — sub-project D3

**Status:** design, approved 2026-08-19.
**Programme:** commercial games. See `2026-08-18-commercial-games-programme-design.md` for the
umbrella decisions P1–P6, `2026-08-18-points-ledger-design.md` (D1) for the ledger this writes to,
and `2026-08-19-level-skipping-design.md` (D2) for the first negative rows.

**Base:** rebased onto `master` at `af1033a`, which contains both D1 and D2 (PR #120, merged
2026-08-19). The conflict this spec originally warned about — D2 and D3 each adding a value to
`PointTransaction::REASONS`, a ledger reason label in seven locale files, and an audit action
label — did not arise: the rebase was clean, because at the time only this document existed on the
branch.

---

## 0. The gap

D1 built the ledger and two ways to earn. D2 built the first way to spend. Both are written **by
gameplay** — a team passes a level, a team chooses to skip one. Nothing in the system lets a person
say "this was wrong" or "this deserved something," and every game that has ever been run has needed
that at least once: a level whose code was mistyped by its author, a team that helped another team
in trouble, a location that was locked when they got there.

D1 anticipated this and deferred exactly one question to here — whether such a row shows its line
publicly or only its effect on the balance (D1 §5). That question is answered below, along with the
ones it turned out to depend on.

---

## 1. Decisions

| | |
|---|---|
| **A1** | **One mechanism, undistinguished.** An operator supplies an amount and a note. There is no "correction" versus "judgement" type. |
| **A2** | **Fully public: the line and its note.** Same as every other row in the ledger. |
| **A3** | An adjustment attaches to **one team's run of one game, or to the team globally**. |
| **A4** | Game-scoped follows the existing `ensure_author` rule; **global is superadmin-only**. |
| **A5** | A **separate writer**, `PointTransaction.adjust!` — never `award!`. |
| **A6** | **No amount cap.** A confirmation page instead, and a compensating adjustment as the remedy. |
| **A7** | Adjustments are allowed on **finished and exited** runs. |
| **A8** | The **note is required** and the **amount must be non-zero**. |

### A1 — why one undistinguished mechanism

A "correction" and a "judgement" would share a table, a writer, a form, an audit entry and a
display. The only thing that would differ is a label, and the label would be chosen by the same
person who chose the amount — so it records what the operator *called* it, not what it was. That
is a field which looks like data and behaves like a comment.

The note already carries the distinction, in the operator's own words, where a reader can weigh it.

### A2 — why the line is public, with its note

This is D1 §5's deferred question, and D1 set out the argument on both sides fairly: an adjustment
is unlike a skip fine because the team did not choose it, may dispute it, and cannot answer it in
the place it is displayed.

Publishing the line wins anyway, for the reason §5 gives for publishing everything else: **the
chart's whole purpose is that a team's standing can be explained.** A team that visibly drops 50
points with no visible cause is the "sees the effect, cannot see why" failure that section
explicitly rejects — and hiding the line does not hide the drop, because the balance is the sort
key.

Publishing the note as well, rather than a bare "adjustment", follows from the same argument one
step further. "−50, adjustment" tells a reader that a person did something to this team and
withholds what. That is worse than either extreme: it advertises a judgement while suppressing its
justification.

The cost is real and worth naming: an operator's wording about a named team becomes a public
sentence, and it cannot be edited or withdrawn (the ledger never reverses). **That is a reason to
be careful about the note, not a reason to hide it** — an operator's judgement being answerable in
public is a feature of a community game, not a hazard of one. A note that would embarrass its
author when published is a note whose adjustment probably needs rethinking.

### A5 — why not `award!`

`PointTransaction.award!` rescues `ActiveRecord::RecordNotUnique` and returns `nil`. That is what
makes an award idempotent — a level re-passed after an operator sent a team back awards once — and
it is precisely wrong here: **two deliberate −50s are two different events, not a retry of one.**

Once §2.1's index change lands, the violation cannot fire for an adjustment at all, and that is
exactly what makes reuse dangerous rather than safe: `adjust!` would carry a rescue that is
currently unreachable and would silently swallow a real constraint error the day anything about
that index changes. A method whose safety depends on a condition maintained somewhere else is a
trap with a delay on it.

`adjust!` therefore does not rescue. A constraint violation is a bug, and it should say so.

### A6 — why no cap, and what replaces it

A cap refuses `−10000`. It does not refuse `−500` entered against the wrong team, which is equally
unrecoverable and rather more likely, and it needs a configuration knob and a settings label in
seven locales.

The confirmation page D2 already built and reviewed covers both cases: a `GET` naming the **team**,
the amount, the note, and the team's **current balance and what it will become**, then a `POST`
that writes the row. No JavaScript (this app has neither Turbo nor rails-ujs, so `data-confirm` is
inert markup), no configuration, and the check sits at the moment of the mistake.

When one gets through anyway, the remedy is already in the design: the ledger never reverses, so a
wrong adjustment is answered by a **compensating adjustment**. Both rows stay visible. That is not
a workaround for a missing edit feature — it is what a ledger is, and the pair is a more honest
record than a silently corrected single row.

### A7 — why finished and exited runs are allowed

D2 refuses a skip on a finished or exited run, and copying that here would be a mistake. A skip is
an action *during* play; an adjustment is usually a judgement made *after* it — a dispute settled
the next morning, a broken location confirmed once the game is over. **The most common adjustment
is one nobody could have made while the run was live.**

**Correction, found during Task 2: "finished" means two different things here, and this decision
needs both.** They are guaranteed by different mechanisms, and an earlier draft of this section
conflated them:

* **A finished or exited GamePassing** — the team's own run is over. *Nothing blocks this.* No
  filter on `InterventionsController` reads the passing's state, so an adjustment on a finished run
  works with or without any exemption. Worth an example anyway, because it would break the day
  someone adds a passing-state filter, but it proves nothing about the exemption.
* **A Game that is no longer live** — the author has finished it, or it is a draft, or withdrawn.
  *This is what `ensure_game_is_live` blocks*, and it is the case the exemption in §4.1 exists to
  serve. It is also the likelier one in practice: a dispute settled the next morning is settled
  after the author closed the game, not merely after one team stopped running.

So the exemption is load-bearing, and only a test that finishes the **game** demonstrates it. This
was established by instrumenting the filter to confirm it was reached and evaluating `live=true`
while the passing-level examples passed regardless.

---

## 2. Data model

### 2.1 `point_transactions` — three changes

| Change | Reason |
|---|---|
| `game_passing_id` and `game_id` become **nullable** | A team-global adjustment belongs to no run and no game. |
| Add `note`, **text**, nullable at the database | Required by validation for adjustments only; every existing row has none. `text` rather than `string`: an operator explaining a disputed penalty writes a sentence or three, and a 255-character ceiling would truncate exactly the adjustments that most need explaining. |
| The per-attempt unique index gains `AND reason <> 'adjustment'` | Without it, a team can be adjusted at most **once per attempt, ever**. |

`reason` gains `"adjustment"` in `REASONS`. It stays a fixed set: the display renders
`t("...reasons.#{reason}")` from that set precisely so an unrecognised value cannot print
`translation missing:` onto a public page. The operator's sentence lives in `note`, which is
**operator-authored content and renders verbatim**, never through `t()` — the same rule that governs
game titles and level descriptions.

`created_by_id` already exists and already records the actor; D1 added it and D2 began using it.

**Two associations must become optional in the model, not merely nullable in the database.**
`belongs_to` is required by default since Rails 5, so `belongs_to :game_passing` and
`belongs_to :game` on `PointTransaction` each need `:optional => true`. Without it the column is
nullable and the model still refuses to save the row — a validation failure that reads like a bug
in `adjust!` rather than a missing option, because the migration plainly succeeded.

Making them optional weakens nothing for the rows that have them: every writer except `adjust!`
sets both from a passing, and §6 keeps an example proving an award still cannot be written without
one.

#### Why the index change is needed, and why its absence would look fine

The existing index is `[game_passing_id, reason]` unique `WHERE level_id IS NULL`.

**NULLs are distinct in a SQL unique index.** So for a **global** adjustment, where
`game_passing_id` is NULL, any number of rows is permitted with no change at all. For an
**attempt-scoped** adjustment, where it is set, the second adjustment on the same attempt is
refused — forever.

Without the change, the feature works for the rarer case and silently refuses the commoner one.
Worse, it works the first time in both cases, which is what anyone tests. This programme has now
been caught by NULL-distinctness three times as a defect; here it is load-bearing in one direction
and hostile in the other, which is a more dangerous shape than either.

#### What nullability does elsewhere, all of which is already correct

* **`Game#deletable?`** requires `point_transactions.empty?`. A global adjustment has no `game_id`,
  so it blocks no game's deletion.
* **`Team#deletable?`** requires the same, and a global adjustment **does** block it — correctly; it
  is a record of something that happened to that team.
* **The test-run sweeps** (`finish_test`, `TestAdmission#revoke!`) delete by run and by passing, so
  global rows are untouched.
* **`Team#balance`** sums by `team_id` and is unaffected.

### 2.2 The display consequence D1 did not anticipate

`teams#show` groups a team's rows **by game**, and D1's §5 amendment renders a neutral placeholder
for a game the viewer may not see. Both assume a game exists.

A global adjustment has none, so the page needs a section for rows that belong to no game — and
the placeholder logic must not treat "no game" as "a game you may not see". They are different
statements: one says *there is nothing here to name*, the other says *there is something here you
are not entitled to see*. Rendering the second for the first would tell every reader a game exists
where none does.

---

## 3. The action

```ruby
PointTransaction.adjust!(team:, amount:, note:, actor:, passing: nil)
```

* `passing` nil ⇒ a global row: `game_passing_id` and `game_id` both NULL.
* `passing` present ⇒ `game_passing_id`, `game_id` and `team_id` denormalised from it, as `award!`
  already does, so the chart and the history aggregate without joining.
* `level_id` is always NULL. An adjustment is not about a level; §8 records why a level-scoped
  variant is deferred rather than absent.
* No rescue. See A5.

**Validations, on adjustment rows only:** `note` present, `amount` non-zero. Every pre-existing row
has no note, so the validation is conditional on the reason rather than on the column.

**Refusals** raise `ArgumentError`, the convention `InterventionsController#refused` already
rescues.

**Nothing about ranking changes.** Points are a parallel currency (P6): an adjustment moves the
chart and never touches `finished_at` or `penalty_seconds`.

---

## 4. Surfaces

### 4.1 Game-scoped

A `adjust` action on `InterventionsController`, rendered from
`app/views/game_passings/_intervention_controls.html.erb` beside `move` and `reinstate`, behind the
existing `ensure_author` — "the author, any superadmin, or an operator on a gated game."

Unlike its neighbours it must **not** be gated on the game being live (`ensure_game_is_live`), per
A7. That filter is currently declared for the whole controller, so this action needs an exemption
rather than inheriting it — and that exemption is the single most likely thing to be got wrong in
this sub-project, because inheriting the filter looks correct and fails only for the case A7 exists
to serve.

### 4.2 Global

In the admin teams console, superadmin-only. A global adjustment reaches every game a team has ever
played, so the narrower authority matches the wider blast radius.

### 4.3 The confirmation page

One shape for both, per A6: a `GET` naming the team, the amount, the note, the current balance and
the resulting balance; a `POST` that writes. Server-rendered — this app has no Turbo and no
rails-ujs, so a `data-confirm` dialog would be inert markup and the click would go straight
through.

### 4.4 Where an adjustment is visible afterwards

* The team's history page — an itemised line with its note, publicly, and under §2.2's new
  game-less section when it is global.
* The chart — through the balance.
* The admin audit — always, with the actor, the team, the amount and the note.

---

## 5. i18n

New keys in **all seven** locales (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`): the `adjustment`
ledger reason label, the form labels and the confirmation page, the refusal messages, the
game-less section heading on the history page, and the audit action labels.

`spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a subset check for the other five, so
completeness elsewhere is the implementer's job. `spec/i18n_audit_actions_spec.rb` reads audit
action names **out of the controllers**, so a missing audit label fails that spec rather than
rendering the raw identifier — which is how `update_settings` sat unnoticed in production until
someone spotted it in a screenshot.

**The note is never translated and never interpolated into a translated sentence.** It is
operator-authored free text; rendering it verbatim in its own element avoids both the
`translation missing:` hazard and the Turkish/Georgian rule about case suffixes attaching to
user-authored values.

---

## 6. Testing

Model:

* a global adjustment writes NULL `game_passing_id` and `game_id`, and counts toward `Team#balance`;
* an attempt-scoped adjustment denormalises `team_id` and `game_id` from the passing;
* **two adjustments on the same attempt both succeed** — the index change, and the example that
  fails without it;
* two global adjustments on the same team both succeed;
* `note` required and `amount` non-zero, on adjustment rows only, with a pre-existing award row
  still valid with no note;
* `adjust!` does **not** rescue `RecordNotUnique` — mutation-tested by forcing a violation;
* an **award** still cannot be written without a passing, so relaxing the two `belongs_to`
  associations to `:optional` has not quietly relaxed them for every other writer.

Authorization, driven over real HTTP on both doors:

* game-scoped: author, superadmin and operator-on-a-gated-game admitted; an ordinary user refused;
* global: superadmin admitted; an operator refused; an author refused; a signed-out visitor refused;
* **an adjustment on a finished run and on an exited run succeeds** — A7, and the thing most likely
  to be broken by inheriting `ensure_game_is_live`.

Display:

* the note renders verbatim, including a value containing markup, which must be escaped and not
  interpreted;
* a global adjustment appears in the game-less section, and **not** under the "game you may not
  see" placeholder — §2.2;
* a negative adjustment sorts and totals correctly on the chart.

Regression:

* the inherited Cucumber contract, **228 scenarios / 2325 steps**, unchanged;
* D1's and D2's idempotence still holds: the index change must not weaken `level_completed`,
  `game_completed` or `level_skipped`. An example per reason, since the changed index is shared by
  all of them.

**Assert row counts, not balances** — a wrong sign and a missing row cancel.

Every request example needs `set_game_schedule!` and a positive status assertion beside any
negative one: `starts_at` lives on `game_runs`, not `games`, and defaults to 2099, so an
unscheduled game 401s and `not_to include` then passes on the error response. Ten examples in this
programme have passed against broken code or vacuous fixtures, and this was the commonest cause.

---

## 7. Sequencing

1. The migration, `REASONS`, the validations, and `adjust!`.
2. The game-scoped intervention, including the `ensure_game_is_live` exemption.
3. The global adjustment in the admin teams console.
4. The confirmation page shared by both.
5. The history page's game-less section.

---

## 8. Out of scope

* **Editing or deleting an adjustment.** The ledger never reverses (D1 P3/P4). A compensating
  adjustment is the remedy, and both rows stay visible.
* **A level-scoped adjustment.** `level_id` and the per-level index would support it, and
  "this level was broken, here is 20 points back" is a real case — but it needs its own answer to
  how it interacts with `level_completed` on the same level, and nothing asks for it yet.
* **An amount cap.** A6.
* **Distinguishing corrections from judgements.** A1.
* **Notifying a team that it was adjusted.** This app has no notification mechanism beyond email,
  and adding one for this is a larger question than this sub-project.
