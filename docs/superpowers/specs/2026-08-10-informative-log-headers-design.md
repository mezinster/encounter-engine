# Informative headers on the log screens — design

**Date:** 2026-08-10. **Decided by:** repository owner (`mezinster`), in session.

The four log screens show answers from exactly one run of one game and say almost nothing about
which. This gives all four a shared header carrying the game, the run, its date, a switcher, the
counts and the time zone.

Follows the game-runs programme (specs of 2026-08-10, phases 1–3) and the operator-entries and
run-scoped-logs work, all merged and deployed.

## 0. Why

**The full log is the only log screen with an anonymous title.** Its three siblings name their
subject — `Лог ответов команды "X" по игре "Y"`, `Прямой эфир игры "X"` — while this one says only
`Полный лог ответов`. An author arriving from the statistics page has no confirmation of what they
are looking at.

**None of the four names its run**, and since the run-scoped-logs change all four accept
`?run=<ordinal>` with **no UI that produces such a URL**. The capability shipped without a door: the
only way to read run 1's log today is to edit the address bar by hand.

**The times have no date and no zone.** Cells print `%H:%M:%S`. For a run that happened days ago in
another timezone, that is not enough to place an answer in time. This bit in practice on
2026-08-10, when a run stored `17:00` UTC and was read as local.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | Which screens? | **All four.** The gap is identical on each, and a shared partial makes it one change rather than four. |
| D2 | Reuse the results page's switcher? | **Yes — extract it.** It is currently inline in `show_results.html.erb`; it becomes `shared/_run_switcher` with two callers. |
| D3 | How are switcher links built? | **From `request.path` plus merged query parameters**, as `shared/_pager` already does — not from named routes. |
| D4 | Counts on which screens? | **All four**, in the shared header. |
| D5 | Show the run line on a single-run game? | **Yes.** Only the *switcher* stays hidden. |
| D6 | Pluralise the counts? | **No.** `Команд: 3`, not `3 команды`. |

### Why D3

The four log screens take different path parameters (`team_id`, `level_id`), so a partial building
named routes would need a per-caller URL lambda. `run` is a **query** parameter on all five pages
including the results page, so `request.path` plus merged query parameters produces the correct URL
everywhere with no branching — and it makes `?run=` and `?page=` survive each other for free.

Switching runs while on page 5 is safe without special handling: levels are game content shared by
every run, so the full log's page count does not change between runs, and `page_of` clamps anything
out of range on the live channel.

### Why D4

The counts describe the **run** (teams that played it) and the **game** (levels), not the screen, so
they read correctly on all four. The alternative — full log only, because that is where the matrix
dimensions matter — was rejected as it puts per-screen branching into a partial whose whole purpose
is to be the same everywhere.

Cost is one `COUNT` per page on the three screens that do not already load `@teams`. The full log
has them loaded already.

### Why D5

Three of the four games in production have exactly one run. Suppressing the run line there would
mean the common case gains nothing from this work, which defeats the point — and the date is the
part that was missing, not the ordinal.

The **switcher** is different and stays hidden below two runs, both because there is nothing to
switch to and because several frozen scenarios render these pages for single-run games.

### Why D6

Russian needs three plural forms, and **this application has never used I18n pluralisation** — no
`one:`/`few:`/`many:`/`other:` key exists anywhere, and the three `t()` calls that pass `count:` use
plain `%{count}` interpolation (`"Коды (%{count}):"`). `rails-i18n` is in the Gemfile and supplies
the CLDR rules, so a pluralised key would now work; being the first to exercise that path, in seven
locales, for a count in a header, buys nothing. The colon form is plural-safe in every registered
language.

---

## 2. The two partials

### `app/views/shared/_run_switcher.html.erb`

Extracted from `show_results.html.erb` unchanged in behaviour. Locals:

| local | meaning |
|---|---|
| `runs` | every run of the game, in ordinal order |
| `current` | the run being displayed |
| `linkable` | the runs that may be offered as links |

`linkable` is an explicit array rather than a predicate, so each caller states its own rule and the
partial contains no policy:

- `game_passings/show_results` passes `@game.runs.select(&:results_visible?)` — its started-run guard
  refuses the rest, and offering a link the guard would answer with a bare 401 is the defect fixed
  on 2026-08-10.
- The log header passes `@game.runs` — **no started-run guard applies to the log screens**, which are
  gated by `ensure_author` and `ensure_full_log_access` only. Every run they name is one they will
  serve.

Renders **nothing at all** when `runs.size <= 1`.

### `app/views/shared/_run_context.html.erb`

The header, rendered at the top of all four log views. Reads `@game` and `@run`; renders

1. the run line — «Забег №2 — 10 августа 2026», the date via `l(run.starts_at.to_date, :format => :long)`, and `—` when `starts_at` is nil;
2. the counts — «Команд: 1 · Уровней: 77»;
3. the switcher;
4. the zone statement — «Время указано в UTC+4».

## 3. The full log's title gains the game

Only the full log needs one; the other three already name their subject.

```
Полный лог ответов игры «Викторина»
```

**`Полный лог ответов` must remain a contiguous substring.** Five frozen scenarios assert it, six
times — `features/logs/log.feature:93, 103, 109, 111, 123, 133` — through
`Then /должен увидеть "(.*)"$/`, which is `have_text(:all, text)`: a substring match with
`Capybara.default_normalize_ws = true`. Extending the title in front of the game name satisfies
this; the phrase must not be reworded or interrupted.

Nothing on these pages is asserted **absent** — every check in `features/logs/log.feature` and
`features/games/game_full_log.feature` is positive — so adding a header cannot break them by
appearing.

## 4. A zone bug fixed on the way through

`show_results.html.erb` derives its offset from `@game.starts_at`, and `Game#starts_at` **delegates
to `current_run`**. Viewing run 1's results therefore computes the offset from run **2**'s start
date, which prints the wrong zone across a DST boundary.

The new header reads `@run.starts_at` — the run whose times are on screen — and `show_results` is
corrected to do the same. Both fall back to `Time.current` when the run has no start date, as the
existing code does.

## 5. The access rule is load-bearing in two directions — do not "fix" it

`ensure_full_log_access` admits the author, or a player whose team **finished the current run**:

```ruby
game_passing = current_user.team && @game.current_run.passing_for(current_user.team)
```

Reading `current_run` — rather than the run being viewed — has two consequences that are the same
line of code:

1. **A player who finished run 1 loses full-log access the moment run 2 opens.** This is the gap
   raised when `?run=` shipped, and it is real: they can no longer read the log of the run they
   actually played.
2. **It is also what stops a finished player watching a live run.** Were the guard relaxed to accept
   a finished passing in *any* run, a run-1 player could request `?run=2` and read every team's
   submissions in a race still in progress.

So the obvious repair — "accept a finished passing in any run" — trades a missing-access bug for a
live-information leak. A correct fix has to compare the passing against **the run being viewed**, and
refuse a run that is still running. **That is out of scope here** and is recorded so the next person
to look does not take the shortcut.

This design changes nothing about who may see a log. The switcher on the log screens offers only
runs the viewer's guard will serve, because that guard does not vary by run.

## 6. Testing

**Header**

- each of the four screens names its game and its run, and `?run=1` labels itself run 1 rather than
  the current run;
- the run's date appears, and a run with no `starts_at` renders `—` instead of raising;
- the counts report the teams of **the run being viewed**, not of the game — proved by a second run
  with a different team, which is the same shape as the `@teams` scoping bug found in the
  run-scoped-logs work;
- the zone statement is derived from the **viewed** run, pinned across a DST boundary so that
  reading run 1 while run 2 is current cannot print run 2's offset.

**Switcher**

- a single-run game renders **no switcher at all** — the frozen-scenario guard, and the rule already
  broken once in this programme;
- a two-run game links the run that is not current, on every one of the four screens;
- the results page still links only runs whose `results_visible?` is true, and still names the
  others without linking — the extraction must not change its behaviour;
- `?run=` and `?page=` survive each other: switching run from page 2 of the full log keeps the page,
  and switching run on the live channel clamps rather than 404ing.

**Both**

- **Cucumber must stay at exactly 232 scenarios (230 passed, 2 undefined) / 2342 steps.**
- Every new key exists in all seven locale files; `spec/i18n_spec.rb` enforces `ru`↔`en` parity.
- No key uses I18n pluralisation (D6).

## 7. Frozen acceptance surface

No `features/**/*.feature` file is edited. The constraint the frozen scenarios impose is the
contiguous `Полный лог ответов` substring (§3) and the empty switcher on a single-run game (§2).

## 8. Out of scope

Fixing `ensure_full_log_access` (§5). Any change to who may see a log. Pagination changes. The two
per-team log screens keep their existing lack of a pager. No new gem.
