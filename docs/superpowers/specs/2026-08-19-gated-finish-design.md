# A paid game's ending — sub-project G

**Status:** design, approved 2026-08-19.
**Programme:** commercial games. Builds on `2026-08-18-access-gated-games-design.md` (B, the passes),
`2026-08-18-access-codes-design.md` (C), and the points ledger of D1–D3.

---

## 0. The gap

Reported by the repository owner, 2026-08-19: a team that skipped every level of a paid game
finished it and was met with

> Для этой игры нужен доступ. Обратитесь к организатору.

They had paid, they had played, they had finished — and the app told them they needed access.

It is not skip-specific. **Every** gated finish hits it; skipping only makes it reachable in five
minutes. The chain, in `GamePassingsController#gated_passing`:

1. Find the team's newest attempt → serve it **if the pass is not spent**.
2. Otherwise look for another live pass → start a fresh attempt.
3. Otherwise raise `Authentication::Unauthorized`.

And `AccessPass#spent?` is `attempt.finished_at.present?`. So the moment a team finishes, the pass
is spent, step 2 finds nothing, and step 3 fires.

**The code treats "your attempt is finished" as "you have no attempt."** A paying customer who
completed the game becomes indistinguishable from a stranger who never bought anything, and is
handed the stranger's message.

### The second bug, found while investigating this one

**Revoking a pass does not stop a team already playing.**

Step 1 serves the existing attempt whenever `!spent?`, and `spent?` says nothing about revocation.
Nothing anywhere on the play path reads `revoked?`; the only place revocation is honoured is
`AccessPass.next_for`, which filters `revoked_at: nil` and is consulted **only when there is no
attempt to serve**.

So an operator who revokes a pass mid-run prevents a *new* attempt and does not touch the one the
team is in. They play on.

Both bugs are the same shape: `gated_passing` answers *"which attempt should this team play?"*, and
its callers need it to also answer *"and if none, why not?"* — a question it currently resolves to a
single, wrong error.

---

## 1. Decisions

| | |
|---|---|
| **G1** | A finished attempt is **served**, not refused. The team lands on a **dedicated finish screen**. |
| **G2** | The finish screen shows their **time, their place, their points and their itemised ledger**. |
| **G3** | A **revoked** pass gets its own message — neither the stranger's error nor the finish screen. |
| **G4** | Revocation **stops play** on an attempt already in progress. |
| **G5** | A team holding another **live** pass still gets a fresh attempt. Replay is unchanged. |
| **G6** | A genuine stranger still gets the existing refusal. |

### G1/G2 — why a screen of their own rather than a redirect

The cheapest fix is to serve the finished attempt and let the existing machinery run:
`show_current_level` sees `finished?`, calls `render_finished_passing`, which for a gated game
redirects to the game page — where `_pass_standings` already lists every completed attempt by
duration. That works, ships in about three lines, and was the first design considered.

It is not enough, and the reason is what the customer paid for. The game page's standings are a
**league table**: rows for every team, no indication which is theirs beyond reading for their own
name, and nothing about the points they earned. A team that has just spent an evening on a paid
game arrives wanting *their* result, not a table containing it.

So the finish screen names their own outcome first — place, time, points — and carries the standings
beneath it for context.

Everything it needs already exists and none of it is new arithmetic:

* `Game#pass_standings` — completed attempts sorted by `duration`; their place is their index in it.
* `GamePassing#duration` — elapsed, minus operator pauses, plus penalties.
* `GamePassing#seconds_to_hms` — exact and locale-free, chosen over
  `distance_of_time_in_words` because that buckets to the nearest few minutes and made a table
  sorted by duration look arbitrarily ordered.
* `Team#balance` and the attempt's `point_transactions` — the level awards, the completion award,
  any skip fines and any operator adjustments.

### G2 — what the ledger shows here

The rows for **this attempt**, itemised, plus the team's overall balance. This is the one screen
where a customer will look for the points they just earned, and D1's §5 already settled that the
ledger is public — so showing a team their own rows introduces no new visibility question.

A skip fine appears here as a negative row. That is the point: a team that skipped four levels
should see what it cost them, on the screen that tells them how they placed.

### G3/G4 — why revocation is a third answer, not a variant of the other two

The stranger's message is wrong for a revoked team: they *did* have access, and telling them to
contact the organiser about access they were deliberately denied is a runaround.

The finish screen is worse: it would tell a team whose access was withdrawn mid-run that everything
concluded normally, and hide that anything happened.

So revocation gets its own sentence: access was withdrawn, contact the organiser. That is the one
case where "contact the organiser" is genuinely the right instruction, because a person made a
decision and can explain it.

**G4 follows from G3 rather than standing alone.** Once revocation has a meaning on this path, an
attempt whose pass is revoked must stop — otherwise the message is only ever seen by a team who was
not playing at the time, which is the population least in need of it.

### G5 — replay is unchanged, and is why the branch order matters

`gated_passing`'s existing comment records the rule: *"a team who bought a replacement gets a second
attempt rather than being handed the finished one."* That stays true. The new branch sits **after**
the replacement-pass check, so a team holding another live pass replays exactly as today, and only
a team with nothing left sees the finish screen.

---

## 2. The resolution

`gated_passing` becomes an explicit answer to *"what is this team's state?"* rather than a lookup
that raises when it fails:

| State | Result |
|---|---|
| Attempt exists, pass **revoked** | Refuse with the revoked message (**G4**) |
| Attempt exists, pass live | Serve it — play continues |
| Attempt finished, another **live** pass exists | Fresh attempt — replay (**G5**) |
| Attempt finished, no pass left | **Serve the finished attempt** → the finish screen (**G1**) |
| No attempt, a revoked pass exists | Refuse with the revoked message |
| No attempt, no pass ever | The existing refusal (**G6**) |

Two things this must not do:

* **It must not create anything.** The finished attempt is served, never replaced; a team refreshing
  a finish screen must not consume a pass or open a run.
* **It must not change what `spent?` means.** `AccessPass#spent?` is deliberately
  `attempt.finished_at.present?` and its comment records that this is *"today's ENCODING of the
  rule, not the rule itself"*, with `spec/models/access_pass/spent_spec.rb` asserting every state.
  Revocation is a separate axis and is read separately.

---

## 3. Surfaces

### 3.1 The finish screen

A view of its own, reached by the URL the team already has — the play screen path. No new route:
the play screen renders the level when the attempt is live and this when it is finished, the same
way `show_current_level` already branches on `finished?`.

Content, in order: their place and time; their points for this attempt, itemised; the standings.

The team's own attempt is marked in the standings table, so a team scanning it can find themselves
without reading every row.

### 3.2 The revoked message

Rendered rather than raised, for the reason W established for withdrawn games: a bare 401 tells a
person that they are not authorised, which is true here but useless — it does not say *what changed*
or *what to do*. The page says access was withdrawn and to contact the organiser.

### 3.3 Unchanged

The game page keeps its standings and stays reachable — `GamesController#show` has no pass gate, so
a team with a spent pass can already open it. Nothing about the catalogue, the chart, or a team's
public history changes.

---

## 4. i18n

New keys in **all seven** locales (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`): the finish screen's
headings (place, time, points, standings), the revoked message, and the label marking the team's own
row.

`spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a subset check for the other five.
`spec/i18n_play_screen_spec.rb` pins the strings a team reads under time pressure — **the finish
screen belongs on that list**: it is the last thing a paying customer sees, and a fallback would
render it in Russian to a team who chose another language.

Nothing here interpolates a user-authored value into a translated sentence, so the Turkish and
Georgian case-suffix rule does not arise. Keep it that way: render the team name, the game name and
any operator note as their own elements.

---

## 5. Testing

Model:

* `spent?` unchanged — `spec/models/access_pass/spent_spec.rb` must stay green, untouched;
* `revoked?` and `spent?` are independent: a revoked pass on an unfinished attempt, a revoked pass on
  a finished one, a spent pass never revoked.

Request, driven over real HTTP, one example per row of §2's table. The two that matter most:

* **a team that finished and has no pass left gets 200 and their result** — not 401, and **no new
  `GamePassing` and no consumed pass** created by the request. Assert the counts across it, or the
  example passes while quietly enrolling them;
* **a team whose pass was revoked mid-run cannot advance** — the level is unchanged and no ledger row
  is written, and they get the revoked message rather than either the finish screen or the stranger's
  error.

And the case a naive fix breaks:

* **a team holding a second live pass still gets a fresh attempt**, on level 1, with the old attempt
  untouched. G5.

Display:

* the finish screen shows their place, their time as `hh:mm:ss`, and their own ledger rows including
  a negative one;
* their own row is marked in the standings;
* a team that finished a game with **no** points enabled still gets a coherent screen — place and
  time, no points section, nothing blank or zero-filled.

Layout:

* **`bin/measure-play-screen`** — this replaces the play screen for a finished attempt, and neither
  suite can see layout: rack-test parses no stylesheet, so content below the fold is fully "visible"
  to every assertion either suite can make.

Regression:

* the inherited Cucumber contract, **228 scenarios / 2325 steps**, unchanged;
* **every negative assertion needs a positive status assertion beside it.** An unscheduled game 401s
  (`starts_at` lives on `game_runs`, not `games`, and defaults to 2099), so `not_to include` passes
  on an error response otherwise. Twelve examples in this programme have shipped that way.

---

## 6. Sequencing

1. `gated_passing`'s state resolution and the revoked refusal — the model and controller half, with
   §2's table as the example list.
2. The finish screen.

Step 1 lands alone: it changes a security chokepoint that decides who may play a paid game, and it
is provable against §2's table without any new view.

---

## 7. Out of scope

* **Changing what `spent?` means.** §2.
* **A finish screen for non-gated games.** They already have `show_results` and a run's finish
  protocol; this sub-project is about the paid path, and merging the two is a larger question.
* **Notifying a team that their pass was revoked.** They learn on their next request, as with a
  withdrawn game — the app has no push mechanism and building one is not this.
* **Letting a team re-open a finished attempt.** The finish screen is read-only; replay requires a
  new pass, which is G5 and already works.
