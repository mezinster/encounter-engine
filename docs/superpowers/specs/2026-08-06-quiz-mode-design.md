# Quiz levels — games that need no field and no code entry

**Status:** approved 2026-08-06

## The problem

Every game this engine can run requires being somewhere. A level poses a task, the team goes to a
place, finds a code and types it. That is the product, and it is why the play screen is designed
for one hand in the rain.

It also means the engine can only run one kind of game. There is no way to author something people
play from a table, a classroom or a chat group — a quiz, a training exercise, an onboarding round —
because the only way to answer a level is to type a string somebody hid in a city.

Quiz levels remove that requirement. A level presents a question with several options; the team
picks. No field, no code.

## Scope

**Quiz-ness is a property of a level, not a game.** A game may mix freely: walk to the monument,
then answer a question about it. This costs one branch in the play view and nothing in the schema
compared with a game-wide flag, and it avoids forcing an author to decide what kind of game they
are writing before they have written any of it.

**Out of scope:** points or partial credit of any kind; shuffling options per team; any change to
how codes are matched; images or media in options; question banks or reuse across games; timed
per-question limits.

## The model

Three additive changes. No existing column or row is altered.

```
options          question_id, text, is_correct (boolean, default false), position
levels           + wrong_answer_penalty  (integer, seconds, default 0)
game_passings    + penalty_seconds       (integer, default 0)
```

`Option belongs_to :question`; `Question has_many :options, dependent: :destroy`.

### Why a separate table rather than reusing `Answer`

`Answer` currently means *an accepted spelling of the correct code* — several rows per question are
synonyms, and every row is correct by construction. A row representing a deliberately wrong choice
contradicts that meaning everywhere the model appears, and worse, it puts distractors in the very
table the code-matching path reads.

A separate table means **the existing code path cannot change behaviour**. That matters more here
than tidiness: `features/**` is a frozen 234-scenario contract, and with `options` empty the play
path is byte-for-byte the one those scenarios already exercise. The suite becomes a guarantee
rather than something to keep re-checking.

### No type column

**A question is a quiz question if and only if it has options.** There is no mode flag, so there is
nothing that can disagree with reality.

`Question#single_choice?` is "exactly one option is marked correct", and that is what decides radio
buttons versus checkboxes at render time. Authors never choose a control; they mark what is true
and the interface follows.

`Level#quiz?` is "any of my questions has options". A level with none behaves exactly as today,
through exactly the same code.

## Playing a quiz level

`post_answer` gains a single branch at the top: a quiz level reads `params[:option_ids]`; anything
else reads `params[:answer]` and runs untouched.

**Correct means the selected set equals the correct set exactly** — every correct option, and no
incorrect one. Partial credit was considered and rejected: this product ranks teams by elapsed
time and has no concept of a score, so "partly right" has nowhere to go.

A wrong submission adds the level's `wrong_answer_penalty` to the passing's `penalty_seconds` and
does **not** advance the level. The team may try again.

**Every wrong submission is charged, including a repeat of one already tried.** Not tracking which
combinations a team has burned is deliberate: the penalty exists to price guessing, and forgiving
repeats would let a team walk the option space for the cost of a single mistake.

### A level may hold more than one quiz question

The model permits it, because `Level has_many :questions` and each may have options — and it needs
no new rule. Every question with options renders as its own group, and the level advances when all
of them are answered, which is exactly the semantics a multi-code level already has today
(`all_questions_answered?`).

The one thing to be explicit about: a submission carries selections for whichever questions the
team filled in, and **each question is judged independently**. Getting one right and one wrong marks
the first answered and charges one penalty, rather than discarding both.

The `Log` row records the chosen option texts, so the author's answer log stays a complete record
of what teams actually did — the same role it plays for typed codes.

## Wrong answers cost time

Free retries would make a four-option question decorative: a team exhausts it in four clicks. So a
wrong pick costs a fixed number of minutes, set by the author per level.

This is expressed in the currency the game already uses. It is a race decided by elapsed time, so a
penalty needs no new scoring concept — guessing stays possible and costs you the race.

### The penalty must not touch the level clock

`current_level_entered_at` is the sole input to every hint countdown. Moving it backwards to
represent a penalty would bring the next hint **closer** on every wrong answer — punishing a team's
ranking while rewarding them with help, which is precisely backwards. It would also corrupt the one
column that means "when did this team arrive here", which the operator's stats screen displays.

So penalties accumulate in their own column and the level clock is never touched.

### Standings

`Game#place_of` currently ranks by counting passings that finished before yours, straight off
`finished_at`. Left alone, penalties would be recorded and never cost anyone a place.

`GamePassing#effective_finished_at` is `finished_at + penalty_seconds`, and `place_of` ranks on
that. For every game that exists `penalty_seconds` is 0, so the ordering is unchanged.

The results screen shows **finish time, penalty, and total** as three separate figures. A penalty
nobody can see is a penalty nobody believes, and an author fielding "why did we lose?" needs to be
able to point at it.

## Authoring

The level form grows a repeatable options block — text plus a "correct" checkbox — and a penalty
field in minutes.

**There is no mode switch.** Adding an option makes the level a quiz; removing them all makes it a
code level again. The author's action and the level's nature are the same fact.

## Translation

Options are author-written content, so `Option` includes `TranslatableContent` with
`TRANSLATABLE_FIELDS = %w[text]` and a `translation_game` resolving through
`question.level.game`. `Game#translatable_records` must walk options alongside levels, hints and
questions.

**The consequence is deliberate: the publish gate will refuse a multilingual game whose options are
not translated**, exactly as it already does for level text and hints. Without this a game
declaring Ukrainian would show Ukrainian task text above Russian options, with nothing to indicate
anything was wrong — the failure would land on a player mid-game rather than on the author before
publication.

## Testing

Weighted to what would be worst if wrong.

- **A level with no options behaves exactly as before.** The existing 234 cucumber scenarios are
  the real assertion here, but a spec should pin it directly too, because "we did not change that
  path" is a claim worth one test rather than an argument.
- **Correctness is set equality**: all correct options selected passes; a superset including a wrong
  option fails; a subset missing a correct one fails.
- **A wrong answer adds exactly the level's penalty and does not advance the level.**
- **A wrong answer does not move `current_level_entered_at`** — the property the whole penalty
  design turns on, and the one a future refactor is most likely to break silently.
- **`place_of` ranks on effective time**: a team finishing earlier with a large penalty places
  behind one finishing later with none.
- **A multilingual game with untranslated options cannot be published**, and the refusal names the
  missing fields.
- **Radio versus checkbox follows the data** — one correct option renders single-select, several
  render multi-select.
- **A repeated wrong answer is charged again**, and **a level with two quiz questions charges each
  independently** — the two rules most likely to be softened by someone who finds them harsh.

`features/**` is a frozen contract from the Merb port and is not touched. Coverage is RSpec.

## Rollout

Three additive migrations. Nothing changes for any existing game: `options` is empty, both new
columns default to 0, and every code path they touch is guarded by "does this level have options".

## Risks

1. **Set-equality correctness is unforgiving.** A five-option question with three correct answers is
   genuinely hard, and an author may not realise how hard until teams are stuck. Mitigated by the
   penalty being per level, so an author can price guessing cheaply on hard questions — but it is
   worth watching once real games exist.
2. **The penalty is invisible until the results screen** unless the play screen shows a running
   total. It should; if it does not, teams will not connect their loss to their guessing.
3. **Options join the publish gate**, so an author adding one option to a level of a multilingual
   game suddenly cannot publish until they translate it. Correct, but it will surprise someone.
4. **`place_of` changes for every game**, not just quiz games. The arithmetic is identical when
   penalties are zero, but it is a change to the one method that decides who won, and deserves a
   test that would fail if the ordering drifted.

## Out of scope, restated

Points or partial credit; option shuffling; changes to code matching; media in options; question
banks; per-question time limits; any game-wide quiz flag.
