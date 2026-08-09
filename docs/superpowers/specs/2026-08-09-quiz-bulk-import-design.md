# Quiz bulk import — design

**Date:** 2026-08-09. **Decided by:** repository owner (`mezinster`), in session.

Lets a game's author paste a structured block of questions and turn it into quiz levels, instead of
adding them one screen at a time. Originates from real use: on 2026-08-08 seventy-one questions were
loaded into game 4 (`Викторина`) by a console script run over SSH, because there was no way to do it
through the application. This is that script, made a feature.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | Who may use it? | **The game's author**, via the existing `ensure_author`. That filter already admits superadmins (`security_filters.rb:32`), so both halves of the original request are covered by one guard that already exists. **Not captains** — captaincy is a team role with no authoring meaning; any logged-in user can already create a game and becomes its author. |
| D2 | Pasting a question the game already has? | **Skip it and report**, append the rest. Matching is on normalised question text. This is the real workflow: the owner's 71-question list contained the 15 already entered by hand. |
| D3 | Preview before writing? | **Yes, two-step.** Paste → preview → confirm. Nothing is written until confirmation. |

## 2. The format

```
Какая порода собак считается миниатюрным родственником грейхаунда?
A) Уиппет
B) Той-терьер
C) *Левретка
D) Басенджи
E) Салюки
```

- A line that is **not** an option line starts a new question; its text is the question.
- An option line matches `<letter>) <text>` — **any single letter**, not only A–E, so lists running
  past E work.
- A leading `*` on the option text marks it correct.
- Blank lines are ignored.

**One asterisk → radio. Two or more → checkbox.** This needs no model work:
`Question#single_choice?` already decides radio vs checkbox at render time, and
`GamePassing#answer_options!` already requires **set equality** — every correct option and no
incorrect one.

### Rejected input

Any of these rejects the **entire paste**, with line numbers, before anything is written. Partial
imports of malformed text leave an author hand-deleting levels.

| Problem | Why it cannot be accepted |
|---|---|
| A question with **no asterisk** | `quiz?` would be false, so the level becomes a *code* question with no code — a level nobody can pass |
| A question with **fewer than two options** | Not a choice |
| Option lines before any question text | Malformed |

## 3. What each accepted question produces

Deliberately identical to the 71 levels already in `Викторина`, so imported and hand-made levels stay
indistinguishable:

- **Level** — `name: "Вопрос N"` where N continues from the game's current highest position,
  `text:` the question, `any_code_passes: true`, `wrong_answer_penalty: 0`, appended at the bottom.
- **One Question**, plus a **vestigial Answer** with `value: N.to_s`.
- **Options** in pasted order, `is_correct` per asterisk.

### Why the vestigial answer is not decoration

`Level#correct_answer` (`app/models/level.rb:38-42`) reads
`self.questions.first.answers.first.value` with **no safe navigation**, and
`app/views/levels/show.html.erb:26` renders it. A quiz level with no `Answer` row therefore **500s
the level page**.

Two ways out. This design writes the vestigial code, because all 71 existing production quiz levels
already have one and matching them keeps one shape in the data. Making the reader nil-safe and
writing no junk is the cleaner alternative and is recorded here as a deliberate rejection, not an
oversight — it changes behaviour for existing rows and is worth doing on its own, not smuggled in
under an import feature.

## 4. The flow

1. **Paste** — a textarea on a new screen reached from the game page.
2. **Preview** — every parsed question with its correct option(s) marked; duplicates flagged as
   *skipped*; a reconciliation line (`71 parsed → 15 skipped, 56 to add`); parse errors with line
   numbers. **Nothing is written.**
3. **Confirm** — everything created in **one transaction**, so a failure part-way leaves the game
   untouched.

Duplicate matching normalises whitespace and case, the same rule the console script used.

## 5. Authorisation and locking

The whole flow rides the existing chain used by `LevelsController`: `ensure_author`,
`ensure_editing_not_locked`, `ensure_game_was_not_started`. An author cannot bulk-import into a game
that has already begun, for the same reason they cannot add a level to one.

## 6. Out of scope

The importer only ever **appends new quiz levels**. It does not edit existing questions, reorder,
delete, set hints or per-level penalties, or import code-question levels. Those stay in the existing
per-level screens.

## 7. Frozen acceptance surface

`features/**/*.feature` must not be edited. This feature adds a new screen and a new route; no
existing scenario visits either. The game page gains one link — its label must not collide with
strings the frozen scenarios assert are absent from the regions they inspect.
