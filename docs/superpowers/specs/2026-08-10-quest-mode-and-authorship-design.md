# Quest mode in the importer, and authorship transfer — design

**Date:** 2026-08-10. **Decided by:** repository owner (`mezinster`), in session.

Two independent changes, specified together because they were commissioned together. They share no
code and can be implemented and merged in either order.

1. **Quest mode.** The bulk importer
   (`docs/superpowers/specs/2026-08-09-quiz-bulk-import-design.md`) can currently only produce quiz
   levels. It learns to produce ordinary code levels — the standard encounter shape, one code per
   level — from the same paste, deciding per question block.
2. **Authorship transfer.** An author can hand a game to any other player on the instance, and a
   superadmin can reassign any game's author.

---

# Part A — Quest mode

## A1. Decisions

| # | Decision | Answer |
|---|---|---|
| A-D1 | Quest or quiz — decided per block, or for the whole paste? | **Per block, mixing allowed.** One option line → quest; two or more → quiz. A single paste may build both kinds. |
| A-D2 | May a quest task span several lines? | **Yes.** Consecutive text lines join into one level text. |
| A-D3 | What is an imported quest level called? | **«Уровень N»**, N being its position. Quiz levels keep **«Вопрос N»**. In a mixed game the names then say which kind each level is. |
| A-D4 | Is a leading `*` on a lone option an error? | **No — stripped and ignored.** Authors habitually mark the correct answer; `A) *ФОНАРЬ` can only mean one thing. |
| A-D5 | Rename `QuizImport` now that it imports both? | **No.** The user-facing label changes; the class, route and spec names do not. |

## A2. The format

```
Дойдите до угла Киевской и Чуй.
На стене дома — табличка с годом постройки.
Сложите цифры года.
A) 23

Какой город является столицей Беларуси?
A) Брест
B) Гродно
C) *Минск
```

Two levels: a quest level whose text is three lines and whose code is `23`, and a quiz level
exactly as the importer produces today.

The mode rule, per block:

```
options.size == 0  ->  rejected: the block has no answer line
options.size == 1  ->  quest, code = that option's text (leading * stripped)
options.size >= 2  ->  quiz, unchanged (still requires at least one asterisk)
```

## A3. Parser (`app/models/quiz_import.rb`)

**Block boundary changes.** Today the rule is *"any line that is not an option line starts a new
question"*, which is correct only because quiz questions are one line long. Under it a three-line
task silently becomes three questions, two of which then fail validation.

The new rule: **a text line starts a new block only if the previous meaningful line was an option
line, or it is the first line.** Consecutive text lines join with `\n`. Blank lines remain ignored
and therefore do not split a block either.

This is backward compatible by construction. Every existing paste has one-line questions, so every
text line in it follows an option line, so every block boundary falls exactly where it fell before.
A regression example pins this.

**Validation changes.**

| Key | Before | After |
|---|---|---|
| `too_few_options` | fires on `options.size < 2` | **replaced** by a new key firing on `options.size == 0` |
| `no_correct_option` | fires on any block with no asterisk | narrows to blocks with `options.size >= 2` |
| `option_before_question` | unchanged | unchanged |
| `empty` | unchanged | unchanged |
| *(new)* blank code | — | fires when a quest block's code is empty after the `*` is stripped |

The blank-code rule exists because A-D4 makes `*` strippable: `OPTION_LINE` requires at least one
character after `)`, so `A) *` parses as an option whose text is `*` and strips to nothing. Left
unchecked that reaches `Answer`'s presence validation and raises `RecordInvalid` **inside the
import transaction**, turning an author's typo into a 500 instead of a line-numbered rejection.

The old message — «строка %{line}: у вопроса меньше двух вариантов» — becomes false once one option
is legal, so it is replaced rather than reworded in place. The replacement names the shape the
author is missing, e.g. «строка %{line}: у задания нет ответа (строки вида «A) КОД»)».

Whole-paste rejection with line numbers remains the policy: a partial import of malformed text
leaves an author hand-deleting levels.

**A hazard recorded, not fixed.** `OPTION_LINE` matches *any* single letter followed by `)`. With
multi-line text joining, the second line of a task that begins `б) ...` will be read as the code
rather than as prose. This hazard already existed; multi-line text makes it easier to reach. It is
documented in the on-screen format help rather than escaped, because an escape character is new
syntax for a case no author has yet hit.

## A4. Writer (`app/models/quiz_import/writer.rb`)

`create_level` gains one branch on the block's mode. Nothing else in the class changes.

**Quest block →**

- **Level** — `name: "Уровень N"` (N = position, continuing the game's numbering), `text:` the
  joined block text, `any_code_passes: true`, `wrong_answer_penalty: 0`, appended at the bottom.
- **One Question**, with **one Answer** whose `value` is the code.
- **No Options.**

**Quiz block →** entirely unchanged, vestigial answer included (see §3 of the 2026-08-09 design for
why that row is not decoration).

Level numbering is shared: positions run 1, 2, 3, 4 across a mixed paste, and each level takes the
name matching its own kind.

**No play-path change is needed, and this is the point of the design.** A quest question has no
correct options, so `Question#quiz?` is false, so `Level#quiz?` is false, so
`Level#find_question_by_answer` — which explicitly does `reject(&:quiz?)` — matches it, and
`GamePassing#correct_answer?` filters identically. The imported level is indistinguishable from one
typed in on the per-level screen.

Duplicate detection is unchanged. `Writer.normalise` collapses all whitespace and folds case, so a
multi-line task matches its own re-paste.

## A5. Preview screen

`app/views/quiz_imports/preview.html.erb` renders each pending block according to its mode: the
option list with its ✓ glyph for quiz blocks, the code for quest blocks. The reconciliation summary
line is unchanged.

## A6. Naming

`QuizImport`, `QuizImport::Writer`, `QuizImportsController`, the `game_quiz_import_path` route and
the five spec files keep their names. Renaming them to `LevelImport` would touch routes, a
controller, four views and five spec files to say the same thing — churn with no behaviour behind
it.

What does change is the **user-facing label**: «Импорт вопросов» becomes «Импорт уровней», and
`quiz_imports.new.intro` / `quiz_imports.new.example` gain the quest form. New and changed keys go
into all seven locale files; `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and requires the
other five to be a subset.

## A7. Tests

- **Parser** — a single-option block parses as quest; multi-line text joins; a leading `*` on a lone
  option is stripped; a block with no option line is rejected with its line number; a mixed paste
  produces both modes in order; **and a regression example proving an existing one-line quiz paste
  parses byte-identically to before.**
- **Writer** — a quest level's shape: one question, one answer holding the code, zero options,
  `Level#quiz?` false, name «Уровень N».
- **Request** — the preview shows the code for a quest block; confirming creates the level.
- **Play path** — an imported quest level accepts its code through `GamePassing#check_answer!`.
  This is the example that proves the feature, because it is the one that crosses the `quiz?`
  boundary the two modes are separated by. A writer spec alone would pass on a level no team could
  complete.

## A8. Out of scope

Unchanged from §6 of the 2026-08-09 design: the importer only ever **appends** levels. It does not
edit, reorder, delete, set hints or per-level penalties. In particular it writes **one** code per
quest level — a level accepting several spellings is built by adding codes on the per-level screen
afterwards, because a second code line is precisely what makes a block a quiz block.

---

# Part B — Authorship transfer

## B1. Decisions

| # | Decision | Answer |
|---|---|---|
| B-D1 | Must the recipient accept? | **No.** Immediate, like `Team#set_captain!`. No pending row, no expiry, nothing to garbage-collect. |
| B-D2 | Which games may an **author** hand over? | Draft, scheduled and finished. **Refused** while the game is running, and while editing is locked. |
| B-D3 | Which games may a **superadmin** reassign? | **Any**, with no lifecycle refusals. |
| B-D4 | How is the recipient named? | **Exact nickname**, typed. |
| B-D5 | Is it audited? | The superadmin path always. The author path only via the existing `acting_as_operator?` rule. |

B-D2 mirrors `TeamsController#hand_over` exactly, including its shape: the member-initiated change
waits for the race to end, and the superadmin path is deliberately unguarded.

## B2. Model

```ruby
Game#transfer_authorship_to!(user)
```

is the **only writer of `author_id` after creation**, the same single-writer discipline that makes
`Team#set_captain!` auditable. `Game#created_by?` and `User#author_of?` both read `author_id` and
need no change.

**`update_column`, not `update!`.** The superadmin path has no lifecycle refusals, so it can target
a running game — and a running game fails its own validations, because
`game_starts_in_the_future` adds an error whenever `starts_at` is past and `author_finished_at` is
nil. `update!` would raise `RecordInvalid` on exactly the games the operator path exists for.

This is not a hypothetical. The comment above `Game#withdraw!` records that `withdraw!`, `restore!`,
`unfinish!`, `lock_editing!` and `unlock_editing!` all shipped using `update!`, 422'd on every
started game, and kept their specs green because `create_game` defaults `starts_at` to 2099, so no
example had ever exercised a started game. **The model spec here must transfer a started game
explicitly**, or this design reproduces that bug exactly.

## B3. Entry points

```
Game#transfer_authorship_to!(user)
   ├── GamesController#hand_over          POST /games/:id/hand_over
   └── Admin::GamesController#set_author  POST /admin/games/:id/set_author
```

Routes mirror `resources :teams do post "hand_over", on: :member end` and
`namespace :admin { resources :teams do post "set_captain", on: :member end }`.

### Author path

Filters: `find_game`, then `ensure_author` — which admits superadmins, per the documented security
chokepoint in `SecurityFilters`.

In the action, in order, each returning **before anything changes**:

| Condition | Result |
|---|---|
| `@game.editing_locked?` | refuse — the lock means *under investigation*, and letting its author pass the game to a clean account is an escape hatch from the lock |
| `@game.started? && !@game.author_finished?` | refuse — B-D2 |
| nickname resolves to nothing | refuse, generic message |
| nickname resolves to `current_user` | refuse, same generic message |
| otherwise | `transfer_authorship_to!`, redirect to the game with a notice naming the new author |

Refusing before the change matches `Admin::UsersController#revoke`, `#move` and `#destroy`, so no
audit entry is ever written for a transfer that did not happen.

Lookup is `User.find_by(:nickname => params[:nickname])` — **exact**. Unlike `Team#set_captain!`
there is no `members` association to scope the lookup through, because the target is any user on the
instance; exactness is therefore the guard rather than a convenience. Not-found and self-transfer
share one message, so the field does not become a probe for which nicknames exist, and that message
names the remedy — the convention every refusal in `Admin::UsersController` already follows.

`record_admin_action("hand_over_authorship", @game, "old -> new")` fires only when
`acting_as_operator?(@game)`, matching every other action in `GamesController`: an author acting on
their own game is ordinary use, not an administrative act.

### Superadmin path

`Admin::GamesController` gains its first non-`:index` action. Filters are the controller's existing
`require_authentication!` + `require_superadmin!`. No lifecycle refusals. Unknown nickname redirects
with an alert; everything else transfers.

`record_admin_action("set_author", game, "old -> new")` always.

`spec/requests/admin_audit_spec.rb` enumerates the audited actions and is the guard against a new
action shipping unaudited. It must be updated deliberately for both new entries — which is the point
of enumerating them.

## B4. Screens

**Author** — a `fieldset` inside the author block on `games/show`, above the delete row, so the
transfer is never the button next to the one the author meant to press (the reasoning already
recorded at `games/show.html.erb:75`). Rendered only when the transfer would be allowed, i.e. not
locked and not running.

Deliberately **not** on `games/edit`: that page sits behind `ensure_game_was_not_started`, so a
finished game — which B-D2 makes transferable — could never reach it.

The author block on `games/show` is gated on `@current_user.author_of?(@game)`, which is not
superadmin-aware, so this form is only ever seen by the real author.

**Superadmin** — an inline `form_with` + text field + submit in the existing per-row control cell of
`admin/games/index`, exactly as `admin/teams/index.html.erb:44` does for `set_captain`.

**A consequence to state plainly.** The moment a transfer lands, the old author loses `author_of?`:
the author block disappears, `edit` raises `Unauthorized`, and if the game is a **draft** they can
no longer open its show page at all (`ensure_author_if_game_is_draft`). That is correct, but it is a
one-way door for them — only the new author or a superadmin can hand it back.

**A side effect worth knowing about.** `Admin::UsersController#destroy` refuses to delete any user
with `created_games`, and `#anonymise` exists as the workaround. Transfer gives that refusal a
second, better remedy: move the games, then delete.

## B5. Tests

- **Model** — the transfer moves `author_id`; **it works on a started game** (the `update_column`
  trap in B2); the old author's `author_of?` goes false and the new author's goes true.
- **Request, author path** — happy path; a non-author is refused; self-transfer is refused; an
  unknown nickname is refused; a locked game is refused; a running game is refused; and *after* a
  successful transfer the old author's `GET /games/:id/edit` is unauthorised.
- **Request, admin path** — a superadmin transfers a **running** game, proving the exemption; one
  `AdminAction` row is written carrying both nicknames in `details`; a non-superadmin is refused.
- **i18n** — new keys in all seven locale files.

## B6. Out of scope

No transfer history beyond the audit row; no notification to the new author, who sees it next time
they open the game; no bulk "move every game of this user"; no undo other than transferring back.

---

# Frozen acceptance surface

`features/**/*.feature` is not edited by either part.

Part A adds no new screen and no new route — it changes what an existing screen accepts. Part B adds
two routes and two forms; no existing scenario visits either.

The label caution recorded at `games/show.html.erb:63-66` — a new label on the game page must not
collide with a string a frozen scenario asserts is *absent* from the region it inspects — was
checked rather than assumed. `features/levels/create-level.feature` carries no absence assertions at
all, and the only `не содержит` assertion anywhere in `features/` is «Игра не содержит заданий»
(`features/games/empty-game.feature:31`). Neither «Передать авторство» nor «Импорт уровней»
collides.
