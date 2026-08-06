# Redundant codes — design

**Date:** 2026-08-06
**Status:** approved, not yet implemented

A level holding several codes currently requires the team to find **all** of them.
This adds a per-level switch so an author can instead say **any one code passes**,
and makes that the default for newly created levels.

---

## Why this exists

The existing behaviour is not an accident. Both feature files that drive it name
their purpose:

> **Функционал: Создание автором нескольких кодов в одном задании (#88)**
> Чтобы разместить **несколько меток на одной локации** автор должен иметь
> возможность добавлять сразу несколько кодов в одно задание

Several physical markers at one location, all of which must be found. That is a
designed game mechanic and it stays.

Separately, the application already has redundancy: a `Question` may hold several
`Answer` variants (`фломастер` / `flomaster`), any one of which is accepted. It is
reached through each code's "(редактировать)" link.

The trap is that the two mechanisms are both called "код" in the UI, and the
button an author naturally reaches for — **"Добавить ещё один код"** — is the one
that is *not* redundancy. An author intending typo-tolerance silently builds a
level requiring three separate codes, and (before PR #18) could not undo it.

This design does not merge the two mechanisms. Making multiple questions behave
as redundancy unconditionally would leave `Question` and `Answer` semantically
identical — two data models for one concept — and would delete #88. Instead the
author chooses, per level, and the default matches the expectation people
actually bring.

---

## Global constraints

- Rails 8.0.5.1, Ruby 3.3.12 (rbenv; not on `PATH` in non-login shells — prefix
  commands with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`).
- Baselines that must hold: **234 cucumber scenarios** (2 pre-existing
  "undefined") / **2362 steps**, and the RSpec suite green (730 examples at the
  time of writing, 6 pending, on `fix/level-form-clarity`).
- **No `.feature` file may be edited.** Step definitions are editable and carry
  the compatibility (§6).
- Every new user-facing string is a `t()` key in all four of
  `config/locales/{ru,en,uk,ka}.yml`, with real Ukrainian and Georgian.
- Hash rockets (`:key => value`); match the surrounding file.
- A running game fails its own validations (`game_starts_in_the_future` fires
  when `author_finished_at` is nil and `starts_at` is past), so every write to a
  live row uses `update_column`.

---

## 1 · The column

One migration, `db/migrate/*_add_any_code_passes_to_levels.rb`:

```ruby
class AddAnyCodePassesToLevels < ActiveRecord::Migration[8.0]
  def change
    # Two steps, deliberately. add_column with a default BACKFILLS every
    # existing row, so the default has to start false to leave live games
    # exactly as they are; only then is it flipped for rows created afterwards.
    # A single statement cannot express "existing rows false, new rows true".
    add_column :levels, :any_code_passes, :boolean, :default => false, :null => false
    change_column_default :levels, :any_code_passes, :from => false, :to => true
  end
end
```

`null: false` with a default on both sides means no code path ever sees `nil`,
so nothing needs to treat "unset" as a third state.

### Naming

`any_code_passes` states the rule from the player's side, which is the side that
matters: reading `level.any_code_passes?` at the call site says what happens.
The inverse (`requires_all_codes`) would read as a negation everywhere the new
default applies.

A boolean rather than an enum: there are exactly two rules and no third is in
prospect. An enum would buy extensibility nobody has asked for.

---

## 2 · The rule

`GamePassing#all_questions_answered?` becomes mode-aware. It is **renamed** to
`level_answered?` in the same change — under the new mode the old name states
something false, and a method whose name lies is worse than one that is merely
vague.

```ruby
  # Whether the team has done enough to pass this level.
  #
  # Renamed from all_questions_answered?: under any_code_passes that name would
  # be a lie, and this is the only question either caller actually asks.
  def level_answered?
    return answered_questions.any? if current_level.any_code_passes?

    (current_level.questions - answered_questions).empty?
  end
```

Two call sites, both `pass_level! if …`:

- `GamePassing#check_answer!` (`app/models/game_passing.rb:89`) — the typed-code path
- `GamePassing#answer_options!` (`app/models/game_passing.rb:108`) — the quiz path

Both change identically. No other caller exists.

### Flipping the mode never retroactively passes anyone

The check runs only when a team **submits**. A team holding one of three codes
when an operator flips the level to "any" is not moved forward; they pass on
their next correct code.

This is the conservative direction and it is chosen deliberately. Re-evaluating
every `GamePassing` on flip would mean one operator click silently completes a
level for teams who did nothing — and because `pass_level!` also stamps
`current_level_entered_at`, which is the sole input to every hint countdown, it
would rewrite hint timing for every team mid-level at the same moment.

The consequence to accept: a team that has already found a code sees no
immediate change. On a level where they have answered every question that
exists, they are already past it, so the case does not arise; on any other, one
more correct code finishes the level.

---

## 3 · The play screen

`app/views/game_passings/show_current_level.html.erb:47` renders

```
Правильных кодов введено: %{answered} из %{total}
```

whenever `current_level.multi_question?`. The condition becomes
`multi_question? && !any_code_passes?` — counting progress toward a total is
meaningless when any single code suffices, and showing "0 из 3" to a team that
needs only one is actively misleading.

The frozen scenario "Команда не видит количество кодов, если код на уровне
единственный" keeps passing untouched: a single-code level is not
`multi_question?` either way.

---

## 4 · Authoring

### The setting

A radio pair beside `wrong_answer_penalty_in_minutes`, permitted in
`LevelsController`'s strong parameters (`levels_controller.rb:74`). That form is
already unreachable once a game has started, which is exactly the right guard
for an ordinary author — see §5 for the operator path.

**There is no shared form partial.** `app/views/levels/new.html.erb:37` and
`app/views/levels/edit.html.erb:36` each carry their own copy of the form, so
the field must be added to **both** files. Adding it to one and not the other
would leave the setting editable but not choosable at creation — or the reverse
— with nothing failing loudly. Extracting a shared partial is out of scope here;
it is a change to two working screens for no gain this feature needs.

### Visibility on the level page

`app/views/levels/show.html.erb` states the mode beside the codes list, in both
the single-code and multi-code branches:

- `any_code_passes?` → "Достаточно любого из кодов"
- otherwise → "Нужно найти все коды"

This is the change that actually closes the trap. An author looking at a list of
three codes currently has nothing on the page telling them how those codes
combine; the information exists only in the behaviour, discovered during play.

Rendered for single-code levels too, where both modes behave identically — a
one-code level says "Достаточно любого из кодов" and stays true. Suppressing it
there would mean the line appears only after a second code is added, which is
the moment the author has already made the decision blind.

---

## 5 · Changing the mode mid-game

Superadmins only, through `InterventionsController`.

That controller is already "operator actions on a game that is actually being
played": it carries `AdminAudit`, `ensure_game_is_live`, and
`rescue_from ArgumentError`. It also carries one standing rule stated in its
header comment —

> Every action calls a named model method and redirects back to the stats page —
> nothing here writes a column directly, which is what keeps a tired operator
> from producing a passing the model has no path to.

— which this design honours. Two named model methods on `Level`:

```ruby
  # update_column, not update!: a level belonging to a running game cannot pass
  # its game's own validations (game_starts_in_the_future fires once starts_at
  # is past and author_finished_at is nil), so an ordinary write would 422.
  def allow_any_code!
    update_column(:any_code_passes, true)
  end

  def require_all_codes!
    raise ArgumentError, "level has no codes" if questions.empty?

    update_column(:any_code_passes, false)
  end
```

`require_all_codes!` refuses a level with no questions, because "all of nothing"
is not a rule a team could satisfy. `ArgumentError` is the refusal channel the
controller already rescues.

### Authorization: a deliberate deviation

Every other action in `InterventionsController` uses `ensure_author`, which
means *the author, or any superadmin*. This one uses `require_superadmin!`.

The reason is not that authors are less trusted in general — they can already
pause a game and move a team between levels. It is that this specific change
alters the difficulty of a race already in progress, for every team at once,
after some of them have committed effort to the harder rule. An operator doing
it leaves an audited entry and is answerable for it; an author doing it to their
own live game is the same act with none of that.

### Audit

`record_admin_action("level_code_mode", level, mode)` on both actions, called
**directly** — deliberately not through the controller's own `audit(...)` helper.

That helper (`interventions_controller.rb:70`) is
`record_admin_action(action, @game, details) if acting_as_operator?(@game)`, and
`acting_as_operator?` is `superadmin? && game.author_id != current_user.id`. Its
reasoning is sound for the actions it was written for: an author pausing their
own game is ordinary use, and recording it would bury the administrative entries
under routine ones.

It does not hold here. This action is reachable *only* by a superadmin — it is
an operator power by construction, not a routine one an author happens to share
— so a superadmin flipping the mode on a game they happen to own is still
exercising that power, and going through `audit(...)` would silently record
nothing in exactly the case where the actor and the beneficiary are the same
person. That is the case an audit trail exists for.

The target is the **level**, not the game, so the entry names which level
changed; `AdminAction.label_for` picks up `Level#name`. `details` carries the
new mode.

---

## 6 · Frozen features

**No `.feature` file is edited.** Three files assert the all-required behaviour:

- `features/multi-questional-levels/playing-with-additional-codes.feature` —
  eight scenarios on a three-code level, including "Правильных кодов введено:
  2 из 3" and passing the level only after all three
- `features/multi-questional-levels/managing-additional-codes.feature` — authoring
- `features/answers/passing-multi-var-level.feature` — a two-question level where
  one question has two spelling variants

All three keep passing because the two **step definitions** that construct
multi-code levels set `any_code_passes = false` explicitly:

- `features/levels/steps/levels_steps.rb:46` —
  `Given /^в игру "..." добавлено задание "..." со следующими кодами:$/`
- `features/answers/steps/answers_steps.rb:30` —
  `Given /^для уровня "..." есть следующие коды:$/`

Both steps exist for the sole purpose of constructing the #88 mechanic, so
pinning them to all-required states what those features already mean rather than
working around them. Each sets the flag with `update_column` after the level is
built, since the step may run against a game whose start time is already past.

Written as one line in each step with a comment naming this spec, so the next
reader sees why a step sets a flag the feature never mentions.

---

## 7 · Testing

**RSpec — new:**

- `Level#any_code_passes` defaults to `true` for a newly created level, and
  existing rows migrated to `false` (asserted against the migration's behaviour
  by creating a row with the column explicitly false).
- `GamePassing#level_answered?` — true after one answer under `any_code_passes`,
  false after one of three under the old rule, true after all three.
- The typed-code path passes the level on the first correct code under
  `any_code_passes`, and still requires all three otherwise.
- The quiz path (`answer_options!`) behaves identically under both modes.
- Flipping the mode does not move any team: a passing with one of three answered
  stays on its level until it submits again.
- `Level#require_all_codes!` raises `ArgumentError` on a level with no questions.
- `InterventionsController` — a superadmin can flip the mode on a live game; an
  ordinary author cannot; both attempts are checked against `AdminAction` rows.
- A superadmin flipping the mode on **their own** game is still recorded. This is
  the case the controller's `audit(...)` helper would silently skip (§5), so it
  gets its own example rather than being assumed.
- The play screen hides the progress line under `any_code_passes` and shows it
  otherwise.
- The level page states the mode in both branches.

**Cucumber:** 234 scenarios / 2362 steps, unchanged, with no `.feature` file
modified. The two amended step definitions are the whole compatibility story.

**i18n:** the mode labels (form, level page), the two intervention notices, and
the audit action label — roughly ten keys across four locales.

---

## 8 · Out of scope

- Merging `Question` and `Answer` into one concept. Considered and rejected:
  it deletes #88 and requires migrating every existing multi-code level.
- Renaming "Добавить ещё один код". Its exact text is asserted by
  `managing-additional-codes.feature` as a `click_link` target, so it cannot
  change without editing a frozen file. §4's mode line is what disambiguates the
  two buttons instead.
- Re-evaluating existing passings when the mode flips (§2).
- Any per-question or per-code granularity. The rule is a property of the level.
