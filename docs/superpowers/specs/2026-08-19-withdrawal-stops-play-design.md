# Withdrawal stops play, with a reason — sub-project W

**Status:** design, approved 2026-08-19.
**Related:** `2026-08-19-level-skipping-design.md` (D2) surfaced the defect this fixes; the D-scope
cleanup branch deliberately left it out because it is a feature rather than a fix.

---

## 0. The gap

`Game#withdraw!` today is one click from the admin games console. It sets `withdrawn_at`, records
an audit row, and does nothing else.

Specifically it does **not** stop play. `withdrawn?` is checked by `ensure_game_is_live`
(`app/controllers/concerns/security_filters.rb:85`), which guards `InterventionsController` — the
*operator's* tools. It appears nowhere in `GamePassingsController`. So teams already in the game
can still answer codes, and since D2, skip levels.

The result is backwards: **an operator has less power than a team in a game the operator has just
declared broken.** The operator cannot move a stuck team or reset a clock; the team can keep racing.

It is also silent. Withdrawal is what an author reaches for when something has gone wrong — a
location cordoned off, a storm, a code that turns out to be unsolvable — and the people it exists
to protect are told nothing at all.

---

## 1. Decisions

| | |
|---|---|
| **W1** | Withdrawal **stops play**. A team in a withdrawn game cannot answer, skip, or take any action that advances a run. |
| **W2** | The operator chooses the **mode**: *withdraw with freeze* or *withdraw and end*. |
| **W3** | Under freeze, the **clock stops**, reusing the pause mechanism. |
| **W4** | A **reason is required**: a chosen category, which is translated, plus optional free text, which is not. |
| **W5** | Affected teams see the reason **on the play screen**, in place of the level. |
| **W6** | A withdrawn game is **not a 401**. The team gets a page, not a refusal. |

### W2 — why the operator chooses, rather than the design

An earlier draft picked one policy. That was wrong: the two cases are genuinely different events and
only the person pulling the game knows which one this is.

* **Withdraw with freeze** — *"stop, we are fixing this."* A code is wrong, a location is
  temporarily blocked, the weather will pass. Runs stay intact: level, clock and points are exactly
  where they stood, and `restore!` puts everyone back mid-stride.
* **Withdraw and end** — *"this game is over."* The event is cancelled, the night has run out, the
  problem is not fixable tonight. Every in-progress run closes and the results stand as they were at
  that moment.

Baking in either one would force the other to be done by hand, in an emergency, by someone who has
already had a bad evening.

### W3 — why freeze stops the clock

`Game#pause!` already exists and does exactly the right thing: it stamps `current_run.paused_at`,
and `resume!` shifts every in-progress passing's `current_level_entered_at` forward by the held
duration and adds it to `paused_seconds`. That comment is worth reading — the shift is *equivalent*
to not counting the interval, because `current_level_entered_at` is the only input to every
countdown.

If freeze did not stop the clock, an operator would have to remember to pause **before**
withdrawing, and every team would be silently penalised in the standings for an outage that was not
theirs on the occasion the operator forgot. That is the failure mode of an optional step taken under
stress.

#### The overlap that needs care

Pause and withdrawal are independent states, and a game can be in both. Naively pausing on withdraw
and resuming on restore double-counts, or un-pauses a game the operator had paused *before*
withdrawing and expects to stay paused.

The rule:

* Withdraw-with-freeze pauses the run **only if it is not already paused**, and records that it did
  so (`games.withdrawal_paused_run`).
* Restore resumes **only if that flag is set**, then clears it.
* An operator who pauses, withdraws, restores, and resumes gets exactly one held interval, and their
  own pause survives the withdrawal.

`pause!` raises `ArgumentError` on an already-paused game, so the check is not optional.

### W4 — why a category *and* free text

A category alone cannot say *"the code at point 4 is wrong, we are fixing it, stay where you are."*
Free text alone cannot be read by a Georgian-speaking team when the operator writes in Russian.

So the headline is a **category**, translated into each team's own locale, and the detail is
**operator-authored free text**, rendered verbatim and never translated — the same rule that governs
game titles, level descriptions, and the operator adjustment note.

Categories: `technical`, `safety`, `weather`, `cancelled`, `other`. `other` exists so the list never
becomes a reason to pick a wrong category, and it is the one case where the free text is doing all
the work.

### W6 — why a page rather than a refusal

The obvious implementation is another `before_action` that raises. It would be wrong. A 401 tells a
team standing in the rain that they are not authorised — which is both false and useless.

**A withdrawn game renders the play screen replaced by the notice**: the category, the operator's
text, and nothing else. State-changing requests (`post_answer`, `skip_level`, `confirm_skip`,
`exit_game`) are refused, but a `GET` of the play screen succeeds and explains itself.

This is also the only notification mechanism available. There is no Turbo, no rails-ujs, no
WebSockets and no polling in this application, so a team learns on their **next request**. In
practice that is seconds — the play screen is what a team looks at while walking — but the design is
*"the next thing they do tells them"*, not a push, and nothing here should pretend otherwise.

---

## 2. Data model

### 2.1 `games` — four columns

| Column | Type | Meaning |
|---|---|---|
| `withdrawal_category` | string, nullable | One of `technical`, `safety`, `weather`, `cancelled`, `other`. |
| `withdrawal_note` | text, nullable | The operator's own words. Optional. |
| `withdrawal_mode` | string, nullable | `freeze` or `ended`. |
| `withdrawal_paused_run` | boolean, `null: false, default: false` | Whether *this withdrawal* paused the run — see W3. |

All four are set by `withdraw!` and cleared by `restore!`. `withdrawn_at` already exists and remains
the predicate; the new columns describe a withdrawal rather than replacing it.

**`withdrawal_category` is validated against a fixed set, and `withdrawal_note` is not validated at
all.** The category is rendered through `t()` and an unrecognised value would print
`translation missing:` onto a page a team reads mid-race; the note is rendered verbatim and cannot
fail that way.

**The category is required when withdrawing.** Enforced at the action rather than as a model
validation, because `withdraw!` uses `update_column` deliberately — a running game does not pass its
own validations (`game_starts_in_the_future` fails on every game being played), which is the same
trap `pause!`'s comment records.

---

## 3. The action

```ruby
game.withdraw!(category:, note:, mode:)
```

* Stamps `withdrawn_at` and the four columns above.
* When `mode` is `freeze` and the run is not already paused: pauses it and sets
  `withdrawal_paused_run`.
* When `mode` is `ended`: calls `end!` on every in-progress passing, exactly as closing a game does.
  Results stand as they were.

```ruby
game.restore!
```

* Clears `withdrawn_at` and all four columns.
* Resumes the run **only if** `withdrawal_paused_run` was set.
* Does **not** revive ended runs. A game withdrawn-and-ended and then restored is a game with a
  finished field — reinstating a team is an existing, audited operator intervention, and doing it
  implicitly here would resurrect runs the operator deliberately closed.

Both use `update_column` for the reason above, and both are transactional where they touch more than
one row — `resume!`'s comment already argues this: a half-applied resume hands some teams their
countdown back and silently robs others.

---

## 4. Surfaces

### 4.1 The operator

`GamesController#withdraw` becomes a form rather than a one-click POST: category, optional note, and
mode. It is reached from the admin games console where the current button is.

The audit row carries the category, the note and the mode. `spec/i18n_audit_actions_spec.rb` reads
action names out of the controllers, so any new action name needs its label in all seven locales.

### 4.2 The team

`GamePassingsController` gains a check: a withdrawn game renders the notice instead of the level, and
refuses every state-changing action.

The notice shows the translated category and, when present, the operator's text verbatim. It must
not show the game's own title logic any differently than the page already does — this is the team's
own game, which they are plainly entitled to see.

### 4.3 Everyone else

Unchanged. `Game.visible` already excludes withdrawn games from the catalogue, and that is the right
behaviour: a withdrawn game is not on offer.

---

## 5. i18n

New keys in **all seven** locales (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`): the five category
labels, the form's field labels and mode choices, the play-screen notice heading, and the audit
action label.

`spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a subset check for the other five.

**Two things must not be translated**: the operator's note, and anything interpolating it. In
Turkish and Georgian, a case suffix must never attach to an interpolated value — the notice should
render the category and the note as separate elements rather than composing them into one sentence,
which sidesteps the problem entirely.

**Render every composed validation sentence before trusting it.** Nothing in this repository tests
that two separately-correct fragments make one correct sentence, and this has now caught out four
separate changes — most recently a plural noun against a singular verb, which every automated check
passed.

---

## 6. Testing

Model:

* `withdraw!` with each mode, and what each leaves behind;
* freeze pauses an unpaused run and sets the flag; freeze on an **already paused** run does not
  pause again and does not set the flag;
* `restore!` resumes only when the flag is set — and the four-step sequence *pause, withdraw,
  restore, resume* yields exactly one held interval;
* `restore!` does not revive ended runs;
* an unrecognised category is refused.

Request, driven over real HTTP:

* a team in a withdrawn game **gets 200** on the play screen and sees the category and the note;
* the same team is refused on `post_answer`, `confirm_skip`, `skip_level` and `exit_game`;
* a team in a **restored** game is playing again, on the level they were on;
* an operator's intervention tools are refused while withdrawn, as they already are;
* the note renders escaped — drive markup through it.

Regression:

* the inherited Cucumber contract, **228 scenarios / 2325 steps**, unchanged. Withdrawal is not in
  it, but the play screen is the most heavily driven surface in that suite.
* `spec/requests/withdrawal_spec.rb` already exists and covers the started-game case that
  `update_column` was introduced for. It must stay green.

**Every negative assertion needs a positive status assertion beside it.** An unscheduled game 401s
(`starts_at` lives on `game_runs`, not `games`, and defaults to 2099), so `not_to include` otherwise
passes on an error response. This has caught out three examples in the preceding sub-projects.

---

## 7. Sequencing

1. The four columns, `withdraw!(category:, note:, mode:)`, `restore!`, and the pause interaction.
2. The operator's form and the audit detail.
3. The team's play-screen notice and the refusals.

Step 1 lands alone: it changes `pause!`/`resume!` interaction, which every running game depends on.

---

## 8. Out of scope

* **Pushing the notice to a team who is not looking.** No mechanism exists, and building one is a
  larger question than this.
* **Reviving ended runs on restore.** §3.
* **Emailing affected teams.** The app has mail, but a withdrawal is usually resolved in minutes and
  an inbox is the wrong channel for someone standing on a street corner.
* **A withdrawal history.** The columns describe the current withdrawal only; a game withdrawn twice
  keeps no record of the first. The audit log does.
