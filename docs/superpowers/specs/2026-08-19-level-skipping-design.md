# Skipping a level, and the fine it costs — sub-project D2

**Status:** design, approved 2026-08-19.
**Programme:** commercial games. See `2026-08-18-commercial-games-programme-design.md` for the
umbrella decisions P1–P6 this argues under, and `2026-08-18-points-ledger-design.md` (D1) for the
ledger this writes to.

---

## 0. The gap

D1 built a currency and two ways to earn it. Nothing spends it, and nothing lets a team choose.

A team stuck on a level today has exactly two options: keep working it, or leave the race
(`GamePassing#exit!`, captain-only). There is no middle. That is fine for a free community game
where the next code is a walk away, and wrong for a commercial one where a customer paid to play
and a single impossible level ends their evening.

Skipping is the middle. It costs something, it is bounded, and — this is the part that makes it a
D-series feature rather than a gameplay tweak — **the cost is the first debit the ledger has ever
carried.** D1 shipped `amount` as a signed integer for exactly this (P6), and shipped nothing that
could make it negative.

---

## 1. Decisions

| | |
|---|---|
| **S1** | A skip costs **points and/or time**, both configured **per game**, either may be zero. |
| **S2** | The author sets a **cap per run**. `max_skips = 0` means skipping is off; the cap is the feature switch. |
| **S3** | The **last level may be skipped**, which ends the run — but a run finished *by a skip* earns **no completion award**. |
| **S4** | **Captains** skip during play. **Operators** may skip on a team's behalf, as an audited intervention. |
| **S5** | The fine is **charged before the advance**, the reverse of D1's award ordering. |
| **S6** | The cap is **derived from the ledger**, not stored. |
| **S7** | A skip row is written **regardless of `points_enabled`**. |
| **S8** | A skip is **never reversed**. |

### S3 — why a skipped finish earns no completion award

The narrow rule: the award is withheld when **the finishing action itself was a skip**, not when
any skip happened earlier in the run. Skip levels 1–4 and answer level 5, and the completion award
is paid in full.

That looks arbitrary until you ask what the award is *for*. `game_completed` means the team crossed
the line, and the line is the last code. A team that skipped four levels still answered the last
one. A team that skipped the last one never crossed it — the run ended because they said stop.
They still finish, still rank on time, still appear in the finish protocol. They simply do not
collect the award for a thing they did not do.

It is also the cheap rule mechanically. `pass_level!` already computes a `finishing` flag, and
`skip_level!` computes the same one; withholding the award is not calling the method. The broader
rule — *any* skip in the run forfeits the completion award — would need state that outlives the
individual skip, and would punish a team twice for the same choice: once at the fine, once at the
finish.

### S5 — why the fine is charged *before* the advance

D1's ordering is the opposite, deliberately, and its comment says why: a team standing in a street
with a correct answer must advance whether or not the ledger accepts a row. Awarding after the save
means a ledger failure is a bookkeeping problem, never a gameplay one.

**Every term of that argument inverts for a debit.** If the fine fails to write after the advance,
the team gets a free skip — and, because S6 derives the cap from those rows, an uncounted skip also
makes the cap unenforceable. A failure would not merely lose a record; it would hand out the
benefit the record exists to price.

Charging first is safe here for a reason specific to this action: **refusing a skip is a no-op.**
The team stays on the level they were already on, still able to play it normally. Nothing they had
is taken away. That is what separates this from refusing to advance on a correct answer, which
would be catastrophic and is why D1's ordering is right for D1.

The failure mode also self-heals, using D1's index rather than a transaction:

* charge fails → nothing happened; team on their level, cap intact, they may try again.
* charge succeeds, advance fails → team is charged and still on the level. They press skip again;
  `PointTransaction.award!` hits the partial unique index on `[game_passing_id, level_id, reason]`,
  returns `nil` rather than raising, and the advance proceeds. **One charge, no stuck team.**

No transaction spans the two operations, and none should: an enclosing `transaction do` would turn
the rescued `RecordNotUnique` into a poisoned transaction on Postgres while both suites, which run
SQLite, stayed green. `PointTransaction`'s own comment records that trap.

### S6 — why the cap is derived

Skips used = the count of `level_skipped` rows for this passing. There is no counter column.

This follows P4 (derived, not stored) and costs nothing extra, because D1's partial unique index on
`[game_passing_id, level_id, reason]` **already** enforces the thing a counter would have to be
trusted for: a given level can be skipped at most once per run. A stored counter would be a second
account of the same fact, free to drift from it — and the only way to check it would be to count
the rows anyway.

It also means an operator removing a bad row restores an allowance, with no second place to fix.

### S7 — why the `points_enabled` gate does not apply

D1 gates awards on `games.points_enabled`, and the gate exists for one reason: no **existing** game
should start writing ledger rows behind its author's back.

A skip row cannot be written unless the author set `max_skips > 0`. That *is* the opt-in. So the
rule is:

> `points_enabled` gates **awards**. It does not gate **records of a team's own action**.

A game with points off and skipping on writes `level_skipped` rows with `amount = 0`. The cap still
works, the team's history still shows what they did, and no arithmetic changes anywhere.

The alternative — a `skips_used` column on `game_passings` — decouples skipping from the ledger
entirely and was rejected: it reintroduces exactly the stored state S6 exists to avoid, and it
hides the skip from the public history that §5 of the D1 spec says is the point.

#### Testing runs, where S6 and D1's testing rule collide

D1 awards **nothing** on a testing run. Its reason was concrete: an author test-running a
points-enabled game earned real rows, and because `Team#deletable?` requires
`point_transactions.empty?`, the disposable `"nickname (test #N)"` team became permanently
undeletable and both sweeps skipped it in silence.

Applying that rule unchanged to skips breaks S6. If a testing run writes no `level_skipped` row,
the cap has nothing to count, and an author testing their own game can skip without limit — which
is precisely the behaviour they are testing.

**So a testing run does write its skip rows**, and the collision that made D1's rule necessary is
already gone: D1's own fix wave made `finish_test` and `TestAdmission#revoke!` delete a run's
`point_transactions` alongside its passings and logs. The disposable team is collectable again, and
the rows do not outlive the test.

This is a narrower rule than "D2 ignores the testing gate", and the difference matters. An
**award** in a testing run is a fiction — the author did not really earn it, and publishing it
would misreport the chart. A **fine** in a testing run is the mechanism under test: without the
row, the author cannot see whether the cap they configured actually holds. The test-run gate
belongs to awards for the same reason `points_enabled` does.

A test team's negative balance is briefly visible on the chart, exactly as its positive balance
was before the sweep collected it. That transience is pre-existing and unchanged by D2.

### S8 — why a skip is never reversed

The ledger has no reversal entries, by D1's P3/P4. An operator who thinks a skip was wrong moves
the team back with `move_to_level!` — an intervention that already exists, already leaves a state
ordinary play could produce, and is already audited. **The fine stands.** The team is where they
should be; the record of what happened is unchanged.

---

## 2. Data model

### 2.1 `games` — three columns, all `default: 0, null: false`

| Column | Meaning |
|---|---|
| `max_skips` | Skips allowed per run. `0` disables skipping for this game. |
| `skip_points_fine` | Points deducted per skip, as a **positive magnitude**. The author types `25`; the ledger stores `-25`. |
| `skip_time_penalty` | Seconds added to `penalty_seconds` per skip. |

The magnitude/sign split is for the author, not the database. A form field labelled "штраф за
пропуск" that wants a negative number is a support ticket.

All three take a numericality validation (integer, not negative). Each therefore needs an
`activerecord.attributes.game.*` noun **and** an `activerecord.errors.models.game.attributes.*`
predicate in all seven locales — the test environment sets `raise_on_missing_translations`, so a
validator without a message fires correctly and then raises while rendering. In `ru`, `uk`, `be`
and `pl` the predicate agrees in gender with its own noun.

**No per-level overrides.** `levels.points_award` and `levels.wrong_answer_penalty` are both
precedents for per-level costs, so this would be consistent — but nothing asks for it, and each
override is another nullable column carrying the nil-versus-zero rule D1 had to pin by mutation
test. Cheap to add later; not free to carry now.

### 2.2 `point_transactions` — one new reason

`level_skipped`, joining `level_completed` and `game_completed` in `REASONS`. `level_id` is set
(it is the level that was skipped); `amount` is `-skip_points_fine`, which may be `0`.

Nothing else about the table changes. The per-level partial unique index does the work described in
S5 and S6.

---

## 3. The action

`GamePassing#pass_level!` currently does six things in sequence. Three of them are "advance",
and skipping needs exactly those three:

```ruby
def pass_level!
  passed    = self.current_level
  finishing = last_level?
  advance!(finishing)
  award_points_for(passed, finishing)
end

def skip_level!(actor)
  raise ArgumentError, "no skips left" unless skips_left.positive?

  skipped = self.current_level
  charge_skip!(skipped, actor)
  advance!(last_level?)
end

private

def advance!(finishing)
  finishing ? set_finish_time : update_current_level_entered_at
  reset_answered_questions
  self.current_level = self.current_level.next
  save!
end
```

`advance!` is extracted rather than duplicated. Duplication would be safer for the frozen contract
in the short run and is rejected anyway: this repository has already shipped one concept resolved
two ways — `finished_at` versus `status = "exited"`, which D1's whole-branch review caught
disagreeing across two surfaces — and a second copy of "what advancing means" is the same bet.

`charge_skip!` writes the ledger row and, when `skip_time_penalty` is non-zero, charges the time:

```ruby
increment!(:penalty_seconds, game.skip_time_penalty)
```

`increment!`, not read-modify-write, for the reason `answer_options!` already documents at the same
column: two teammates acting at the same instant under `update_column` each read the same starting
value, and one charge is lost. `penalty_seconds` feeds both `effective_finished_at` and `duration`,
so a time fine reaches both the ordinary ranking and the commercial standings with no further work.

**Refusals raise `ArgumentError`**, the convention `InterventionsController#refused` already
rescues: no skips left, a finished or exited run, a game not currently running.

**No awards on a skipped level.** `skip_level!` never calls `award_points_for`, so there is no
`level_completed` row for the skipped level and — when the skip was the finishing action — no
`game_completed` row either. S3 costs one method call not made.

**Two actors, one method.** `actor` decides only what is written to the `Log` line and, for an
operator, what `record_admin_action` attributes. The gameplay effect is identical, which is what
stops the operator path becoming a second implementation of skipping.

**Both paths write a `Log` line**, so the level log an author reads shows a skip where an answer
would otherwise appear.

---

## 4. Surfaces

### 4.1 The captain

The control goes in `.play-exit` in `app/views/game_passings/show_current_level.html.erb`, beside
"Сойти с дистанции" — the other captain-only action that spends something the whole team owns. It
states the remaining allowance and the cost.

**The confirmation is a server-rendered page, not a dialog.** This app has no Turbo and no
rails-ujs, so `data: { confirm: ... }` is inert markup and the click goes straight through. A skip
spends points and a cap slot irreversibly, and a mis-tap during a live game cannot be undone (S8),
so it gets a `GET` that states the cost and the remaining allowance, and a form that `POST`s the
skip. One extra route, no JavaScript, and it works on a phone with a poor connection — which is
the actual operating environment.

### 4.2 The operator

A `skip` action on `InterventionsController`, rendered from
`app/views/game_passings/_intervention_controls.html.erb`, wrapped in that controller's existing
`audit` helper. It shares `skip_level!` and therefore every refusal rule; it does not bypass the
cap.

### 4.3 Where a skip is visible afterwards

* The team's history page (D1, `teams#show`) — an itemised `level_skipped` line, publicly, which
  is what §5 of the D1 spec says the ledger is for.
* The chart — through the balance, since the fine is negative.
* The level log — the `Log` line.
* The admin audit — for operator skips only.

Game identity on the public pages stays gated as the D1 spec's §5 amendment requires: a skip in a
game the viewer may not see renders under the same neutral placeholder.

---

## 5. i18n

New keys in **all seven** locales (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`): three game-form field
labels, the skip button, the confirmation page, the refusal messages, the `level_skipped` ledger
reason label, and the validator messages and attribute nouns from §2.1.

`spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a subset check for the other five, so
completeness elsewhere is the implementer's job and no test will catch its absence.

If any string interpolates a level or team name, Turkish and Georgian put the case suffix on a
common noun instead of the name (`«%{level}» adlı seviye`), per the standing rule in `CLAUDE.md`.

The reason label is rendered from a fixed set, never interpolated from the column, so an
unrecognised `reason` cannot print `translation missing:` onto a public page.

---

## 6. Testing

Model:

* the cap: refused when exhausted, and **derived** — a row removed out of band restores an
  allowance;
* the fine's sign and magnitude, including `skip_points_fine = 0` writing a zero-amount row;
* no `level_completed` row for a skipped level; no `game_completed` row when the skip finished the
  run; a completion award still paid when earlier levels were skipped but the last was answered;
* the time penalty charged through `increment!`, and `current_level_entered_at` reset by the
  advance rather than by the penalty.

Ordering — the part most likely to be quietly broken later:

* **Mutation.** Swap `charge_skip!` and `advance!`, make the charge raise, and assert the team is
  still on the original level. An example that stays green under that swap is not testing S5.
* **Self-heal.** Charge succeeds, advance fails, team retries: exactly one ledger row, and they
  advance.

Divergence from D1's gate:

* a game with `points_enabled` false and `skip_points_fine` 0 still writes its `level_skipped` row
  and still enforces the cap. This pins S7, which is the one place D2 deliberately disagrees with
  D1.
* a **testing run** writes its skip rows and enforces the cap, while still awarding nothing for a
  level passed normally in that same run. Both halves in one example, because the point is that the
  two rules now diverge — an example covering only the skip half would pass against code that had
  dropped the testing gate from awarding as well.
* the test-run sweep removes those skip rows: after `finish_test`, the run has no
  `point_transactions` and the disposable team is deletable. D1 shipped that sweep; D2 is the first
  thing that writes rows into a testing run on purpose, so it is D2 that must prove it works.

Request:

* captain may skip; an ordinary member may not; an operator may; a stranger may not;
* the confirmation page states the cost, and the `POST` is what performs the skip.

Layout:

* **`bin/measure-play-screen`** at 390×680, 375×553 and 1280×800 after the button lands. Neither
  suite can see layout — rack-test parses no stylesheet, and a button below the fold is fully
  "visible" to Capybara. That is exactly how a broken play screen shipped once already.

Regression:

* the inherited Cucumber contract, **228 scenarios / 2325 steps**, unchanged. The play screen is
  the most heavily driven surface in that suite, and `pass_level!` is being restructured, so this
  is the gate that matters most.

**Assert row counts, not balances.** A balance can be right for the wrong reason — a missing fine
and a missing award cancel.

---

## 7. Sequencing

1. The three `games` columns, their validations, and their form fields.
2. `advance!` extracted from `pass_level!`, with the contract green before anything is added.
3. `skip_level!`, `charge_skip!`, the `level_skipped` reason, and the derived cap.
4. The captain's confirmation page and button; `bin/measure-play-screen`.
5. The operator intervention.

Step 2 lands alone and deliberately: it changes the most heavily exercised method in the app and
should be provable as a pure refactor before any new behaviour rides on it.

---

## 8. Out of scope

* **Reversing a skip.** S8. An operator uses `move_to_level!`; the fine stands.
* **Per-level skip costs.** §2.1.
* **Operator adjustments** — a bonus or penalty a person imposes on a team. Still deferred, and
  still carrying the open question the D1 spec's §5 records: whether such a row shows its line
  publicly or only its effect. Note that D1's per-attempt unique index caps any future adjustment
  at one per `(attempt, reason)`, which that design will have to account for.
* **A "skipped" marker on the finish protocol.** S3 withholds the award; it does not label the
  run. Adding a label is a product decision, not a consequence of this one.
