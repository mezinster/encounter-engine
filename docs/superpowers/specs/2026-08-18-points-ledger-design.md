# The points ledger — design

**Date:** 2026-08-18. **Decided by:** repository owner (`mezinster`), in session.
**Sub-project D1 of** `docs/superpowers/specs/2026-08-18-commercial-games-programme-design.md`.

D was originally scoped as one piece: a ledger, awards, fines, skipping a level, and a global
chart. It is split, because skipping is the only part that is **gameplay** — a new control on the
play screen, mid-run, on the same path the frozen acceptance contract drives. Everything else is
accounting: new tables and screens that no existing flow depends on, where a defect is visible in
a chart rather than in a street.

**D1 (this spec)** is the ledger, the awards for what teams already do, and the chart.
**D2** is skipping a level and its fine, which becomes the ledger's first non-award entry.

## 0. The gap

This app measures a game two ways, and both are time. `GamePassing#effective_finished_at` ranks a
scheduled run by finish time plus accrued penalty; sub-project B added duration ranking for
commercial attempts. Neither survives the end of the run: nothing carries across games, so there
is no answer to "how has this team done, overall".

The programme's P6 settled that points are a **parallel currency**, for commercial and ordinary
games alike, and explicitly **not** an extension of the existing time penalties
(`levels.wrong_answer_penalty`, `game_passings.penalty_seconds`). A fine deducts points and does
not move the clock.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| P1 | Is scoring on by default? | **No.** `games.points_enabled`, default false. A game awards nothing until its author turns it on. |
| P2 | Where do the values live? | Game defaults (`level_completion_points`, `game_completion_points`), with a **nullable per-level override** (`levels.points_award`). |
| P3 | Does the ledger ever reverse? | **No.** Append-only, no compensating entries, no confirmation state. |
| P4 | What happens to points when a run is abandoned? | **The team keeps them.** They simply never earn the completion award. |
| P5 | How is double-awarding prevented? | **Two partial unique indexes** — one for rows with a level, one for rows without. Not a Ruby check. |
| P6 | How is an amount stored? | One **signed integer**. A fine is a negative row, not a second column or a type flag. |
| P7 | Where does the chart live? | It **extends `teams#index`**, which already lists every team. |
| P8 | What does the chart rank by? | **Balance**, descending. Nothing time-based. |
| P9 | Who sees what? | **Everything is public**, itemised rows included. Transparency is the chart's purpose. |
| P10 | Does D1 ship operator adjustments? | **No** — but `created_by_id` exists from the start. See §2.1. |

### P3/P4 — why the ledger never reverses

Points are earned at the moment a level is passed. A team that quit on level 4 keeps what levels
1–3 were worth and never earns the completion award; an operator ending the game is the same,
which is consistent with the programme's rule 3, where an operator-caused ending costs the
customer nothing.

The alternatives both cost more than they are worth here. **Voiding on abandonment** needs
compensating entries and a reason code for them, makes a balance something that can fall without
an operator acting, and forces a ruling on whether an operator ending a game counts as
abandonment — which rule 3 says it does not. **Provisional entries** turn the ledger from a log
into a state machine: every balance query filters on confirmation, and a team mid-run sees points
that are not yet theirs.

It also matches the play loop as it already is: `exit!` is terminal, and nothing in this app
un-does progress.

The accepted cost: a team can accumulate partial runs of the same game. For a scheduled game that
requires an entry per run; for a commercial one it costs a purchased pass each time. Both are
priced, so neither is free farming.

### P5 — why the guard is an index

An award must be idempotent, and there are real paths that would otherwise double it. An operator
using `GamePassing#move_to_level!` to send a team back, and the team re-passing the same level, is
the obvious one; a retried request is the other.

The failure is silent and inflationary: the team accumulates points nobody can account for, and
because the ledger never reverses (P3) there is no clean way to remove them. So the guard is a
unique index on `(game_passing_id, level_id, reason)` — in the database, not in a Ruby `exists?`
check, which two concurrent requests both pass.

It takes **two** indexes rather than one, and the reason is worth stating because the single-index
version looks correct. `game_completed` carries a nil `level_id`, and SQL compares NULLs as
distinct in a unique index — so one index on `(game_passing_id, level_id, reason)` would refuse a
duplicate level award and silently permit a duplicate completion award. Two partial indexes, split
on whether `level_id` is null, close both. §7 requires an example that completes one attempt twice,
because nothing else would reveal the gap.

The indexes also settle replays without a separate rule. A second purchased attempt at the same
game has a different `game_passing_id`, so it earns its own awards legitimately.

### P6 — why the amount is signed

A balance is then one `SUM` and never a case statement, and a fine is a negative row. That is what
lets D2 add skipping without touching this table's shape at all.

## 2. Data model

### 2.1 `point_transactions`

```ruby
create_table :point_transactions do |t|
  t.integer  :team_id,         :null => false
  t.integer  :game_id,         :null => false
  t.integer  :game_passing_id, :null => false
  t.integer  :level_id
  t.integer  :amount,          :null => false
  t.string   :reason,          :null => false
  t.integer  :created_by_id
  t.datetime :created_at,      :null => false
end

# TWO partial unique indexes, not one plain one, and the reason is a NULL.
#
# game_completed carries a nil level_id, and SQL compares NULLs as DISTINCT
# in a unique index -- so a single index on (game_passing_id, level_id,
# reason) would permit two completion awards for one attempt while correctly
# refusing two level awards. The hole is invisible in testing unless an
# example completes the same attempt twice.
add_index :point_transactions, [ :game_passing_id, :level_id, :reason ],
          :unique => true, :where => "level_id IS NOT NULL",
          :name => "index_point_transactions_per_level"
add_index :point_transactions, [ :game_passing_id, :reason ],
          :unique => true, :where => "level_id IS NULL",
          :name => "index_point_transactions_per_attempt"

add_index :point_transactions, :team_id
```

`level_id` is **nullable**: `game_completed` is not about a level. That same nullability is what
D2's skip fine will use, since a skip *is* about a level — so the column serves both without D1
anticipating D2.

**`created_by_id` is nullable and D1 never writes it.** An award earned by play has no actor; an
operator adjustment does. The column exists from the start because the audit trail is the reason
this is a ledger rather than a counter on `teams` — the programme design calls balances
commercially sensitive, and "who took 20 points off us, and why" has to be answerable. D1 ships no
operator-adjustment UI (§7), so nothing writes it yet.

**No `updated_at`.** A row in an append-only log is never updated; omitting the column makes that
structural rather than conventional.

### 2.2 `games` and `levels`

```ruby
add_column :games,  :points_enabled,          :boolean, :default => false, :null => false
add_column :games,  :level_completion_points, :integer, :default => 0,     :null => false
add_column :games,  :game_completion_points,  :integer, :default => 0,     :null => false
add_column :levels, :points_award,            :integer
```

`levels.points_award` is nullable and overrides the game default **when set**, including when set
to zero — so an author can make one level worth nothing without turning scoring off for the game.
`nil` means "use the game's value"; `0` means zero.

## 3. Awards

`GamePassing#pass_level!` is the single point every advance goes through. It already branches on
whether the level was the last one, so both awards fall out of the branch that exists:

* every pass writes `level_completed`, worth `level.points_award` or, when that is nil, the game's
  `level_completion_points`;
* the last one additionally writes `game_completed`, worth `game_completion_points` and carrying a
  nil `level_id`.

**Nothing is written when `points_enabled` is false**, and the check happens before any row is
built, so a game with scoring off leaves no trace in the ledger.

**Awarding must not be able to break a run.** A team standing in a street with a correct answer
must advance whether or not the ledger accepts a row. The award is therefore written inside
`pass_level!`'s existing save path, and a `RecordNotUnique` from the idempotency index is
**rescued and ignored** — that exception means the award already exists, which is precisely the
outcome wanted. No other exception is swallowed.

`Team#balance` is `point_transactions.sum(:amount)`. A cached column may follow if it hurts; the
ledger stays authoritative.

## 4. The chart

`teams#index` already lists every team. It gains columns — games started, games finished, points
earned, points deducted, balance — and sorts by balance descending. A second listing would be the
same rows in a different order, and the two would drift.

**Every figure is a grouped query**, keyed by team: aggregates over `point_transactions` and
`game_passings`, never a lookup per row. This programme has introduced the same N+1 three times —
twice through `Game#deletable?`, once through a listing partial — so this screen carries a
query-count example from the start rather than acquiring one after it breaks.

Teams with no transactions appear with a balance of zero. It is a list of teams, not a list of
scorers.

**Per-team history** lives on the team's existing page: which games, when, whether finished, and
what each run was worth in total. A reader following a name from the chart lands somewhere that
already exists.

## 5. Visibility

**The whole ledger is public**, itemised rows included: the chart, each team's per-game totals,
and every individual transaction with its reason.

Transparency is what the chart is *for*. A fine already shows up publicly whatever we do — it is
subtracted from the balance, and the balance is the sort key, so a fined team visibly drops. Hiding
the line while publishing its effect would let a reader see that a team lost ground without being
able to see why, which is the worst of both.

An earlier draft of this spec split aggregates from itemised rows, reserving the detail for the
team's own members and operators. That was withdrawn on review, and the reason is worth recording:
**D1 writes nothing but positive awards.** `level_completed` and `game_completed` are the only two
reasons, so the boundary protected data that does not exist. It was speculative complexity
answering a question D1 never asks.

### The question this defers, and where it will actually arise

Two kinds of negative row are not alike, and only one of them is a genuine product question:

* **A skip fine** (sub-project D2) is the team's own choice, taken during play. Publishing it is
  part of the game's record, like a resignation on a scoresheet. It is public.
* **An operator adjustment** — a bonus or penalty imposed *by a person on* a team — is different in
  kind. The team did not choose it, may dispute it, and cannot answer it in the place it is
  displayed. Whether such a row shows its line publicly or only its effect on the balance is a real
  decision, with a real product argument on each side.

D1 ships no operator adjustments (§9), so that decision is **not made here**. It belongs to
whoever builds that UI, and this section exists so they know it is theirs to make rather than
inheriting a default nobody chose.

## 6. i18n

New keys in **all seven** locales (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`): the three game form
fields and the level field, the chart's column headers, the per-team history headers, the ledger's
reason labels, and the balance label.

`spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a subset check for the other five, so
completeness elsewhere is the implementer's job.

**Reason labels are rendered from a fixed set, never interpolated from the column**, so an
unrecognised `reason` cannot produce `translation missing:` on a public page.

## 7. Testing

* **Model** — the award amounts, including the per-level override and the `nil`-versus-zero
  distinction; nothing written when `points_enabled` is false; `Team#balance` summing signed rows.
* **Idempotency** — both halves of the guard, each exercised the way it can actually fail. A team
  moved back by `move_to_level!` and re-passing the same level earns `level_completed` **once**;
  an attempt driven to completion twice earns `game_completed` **once**. The second is the one a
  single index would miss, so it is not optional. Assert row counts, not balances — a balance can
  be right for the wrong reason.
* **Request** — the chart's figures for a team with a mixture of finished and abandoned runs; the
  visibility split, with a guest and a non-member seeing totals and no itemised rows, and a member
  and an operator seeing them.
* **Query count** — the chart flat as the number of teams grows.
* **Regression** — the inherited Cucumber contract (228 scenarios / 2325 steps) unchanged. The
  award hook sits inside `pass_level!`, which that contract drives constantly, so this is the gate
  that matters most here.

## 8. Sequencing

1. **The ledger and the awards** — table, model, config columns, the `pass_level!` hook. A defect
   here writes wrong numbers that P3 forbids reversing.
2. **The chart and the per-team history** — read-only screens over what step 1 records.

## 9. Out of scope

**Skipping a level and its fine — sub-project D2.** It is the reason `amount` is signed and
`level_id` nullable, and it needs no change to this table.

**Operator adjustments** (a manual bonus or fine). `created_by_id` is ready for them; the UI, its
authorisation and its audit entry are not D1's.

**A cached balance column.** The ledger is the source of truth; caching is an optimisation to make
when a query is measurably slow, not before.

**Anything time-based in the chart.** Sub-project B ranks a *game* by duration; D1 ranks *teams*
by accumulated points. Keeping them apart is what stops the chart becoming a second, worse copy of
the per-game standings.
