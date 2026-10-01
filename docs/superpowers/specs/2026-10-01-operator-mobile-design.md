# Operator on a phone: the live-game screens — encounter-engine

**Status:** approved in conversation 2026-10-01; this is the written spec for review.
**Date:** 2026-10-01
**Programme:** wave item **D** of the 2026-09 visual/UX wave (after B+F #182, A+G #183/#184, E2 #185).

## Goal

An author or operator running a game outdoors, from a phone, can follow it and act on it without
pinching or scrolling sideways — watching progress, settling disputes from the logs, and
intervening (move, reset, pause) **equally** (owner's answer). Today, measured at 390×680 with a
realistic running game (8 levels, 12 teams, ~60 answers):

| Screen | Measured problem |
|---|---|
| Full log `/logs/full/:game_id` | levels × teams matrix 3479px wide inside a 358px scroller; every team past the first cut to a character or two |
| Standings + interventions `/stats/index/:game_id` | one ~170px card per team → 4871px page for 12 teams; Pause scrolls away; the two log links are 19px tall, side by side |
| Game page, per-team level/game logs, admin entries | page-level sideways overflow of 140 / 146 / 146 / 93px from long unbroken names and answers |
| Live channel, standings cards | content clipped inside their own scrollers (358px visible, 484px content) |
| All of them | nothing refreshes itself; no `spec/layout` file measures any of them |

Success: no page-level or inner sideways scroll at 390px on any in-scope screen; standings fit in
about one and a half screens for 12 teams with Pause always reachable; the full log readable on a
phone; the four live screens refresh themselves without disturbing an operator mid-action; desktop
visually unchanged; both suites green with the inherited contract at 228/2325 and `features/`
untouched; two new layout specs.

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Phone priority | All three jobs equally | Owner's answer |
| Refresh | Client-side fragment poll | Keeps scroll, never closes an open intervention panel or discards a half-filled form; meta refresh does all three |
| Full log on a phone | Levels, teams inside (CSS restack of the same markup) | Same reading order as desktop; one template |
| Standings on a phone | Two-line row; actions and log buttons in the existing panel; sticky control bar | Owner's pick; ~64–70px per team |
| Construction | CSS-first on the existing templates (not `request.variant`, not a rewrite) | One template per screen keeps the frozen scenarios exercising the markup phones get |

## §1 Live refresh

`public/javascripts/live_region.js` — vanilla JavaScript, loaded only on the four live screens
(standings, live channel, full log, results), with no dependency.

- A screen marks its data region with `data-live`. Every **20 s** the script fetches
  `location.href` (path and query, so the pager's page is kept) with header
  `X-Requested-With: XMLHttpRequest`, parses the response with `DOMParser`, finds the element with
  the same `id` and replaces the live region's children. Scroll position is kept (restored if the
  swap changes it).
- **Holds**, re-checked each tick: any `<details open>` inside the region (an intervention panel);
  focus in an `input`, `select` or `textarea` anywhere on the page; `document.hidden`. A held tick
  is skipped, not queued.
- **Errors** (network failure, non-2xx, response without the region): nothing is swapped; the old
  content stays; the stamp keeps counting so staleness is visible.
- **Stamp and toggle** in the page's control area: «Обновлено %{seconds} с назад», updated every
  second from the last successful swap; a button «Пауза обновления» / «Возобновить обновление».
  The paused state is remembered in `localStorage` under one key, every access wrapped in
  `try/catch` (private windows throw). The localised strings reach JavaScript through `data-`
  attributes holding the `t()` output with a `%{seconds}` placeholder — plain interpolation, no
  I18n pluralisation (same reason as `shared.countdown.*`; Russian reads «12 с назад»).
- **Without JavaScript** the pages are exactly today's static pages. No controller, route or
  response format changes.
- Rendering: one partial, `shared/_live_status`, emits the stamp, the toggle and the `<script>` tag.

## §2 Standings and interventions (`game_passings/index`, `/stats/index/:game_id`)

**Phone (below 48rem).** `table#stats` gains the modifier `table--compact` (shared with the live
channel, §3) alongside `table--cards`. Under it the `td::before` labels are suppressed and each
`tr` is a two-line grid:

```
Адреналин                    [Вмешательство ▾]
Уровень 8: Парк · 00:12:40
```

- Line 1: team name (`overflow-wrap: anywhere`) and the `summary.btn.team-disclosure`; line 2:
  level · time at level. Exited and finished teams keep today's cell contents
  («Сошли с дистанции» + level name; «Финишировали» + `--:--:--`), shown on line 2.
- An open panel spans the row's full width below line 2. It now begins with two new full-size
  buttons, **«Лог уровня»** (omitted for a finished team, as the link is today) and **«Лог игры»**,
  followed by the existing controls, each ≥44px: move (select full width), reinstate,
  reset clock (`btn--danger`, kept apart), skip, adjust.
- **The original «(лог по уровню)» / «(лог по игре)» link cells stay in the row's markup, unchanged,
  and are hidden on phones by a rule in the external stylesheet.** `features/logs/log.feature:29-61`
  asserts and clicks those links on this page; Capybara's rack-test driver parses no stylesheet, so
  they stay clickable for the frozen scenarios — the construction CLAUDE.md documents for the
  locale dropdown. The panel buttons use different labels, so `click_link` never sees two matches.
  Do **not** hide the cells with an inline style, a `hidden` attribute, or by moving them into the
  closed `<details>` — each is invisible to rack-test.
- **Control bar `.opbar`**: pause/resume (`button_to`, unchanged), «Приостановлена с …» when paused,
  and `shared/_live_status`. In the markup it comes **after** the table; a wrapper (`.ops`, flex
  column) gives it `order: -1` from 48rem so desktop still shows it at the top. Below 48rem it is
  `position: sticky; bottom: 0` with the play screen's `.playbar` treatment (surface background,
  top border, `z-index: var(--z-sticky)`, iOS safe-area inset), so Pause is reachable at both ends
  of the scroll. The «Полный лог ответов» button sits just above it.
- The live region is the `.table-wrap` only — the bar is never swapped, so a tap on Pause never
  lands on a node being replaced.
- Desktop (≥48rem) is visually unchanged; the superadmin level-codes fieldset only gains wrapping.

## §3 Logs

**Full log (`logs/show_full_log`).** `table#stats` gains `log-matrix`. Below 48rem `table`,
`tbody`, `tr` and `td` become `display: block`: the level row is the section heading (name and
correct code), each team cell an indented block. No inner sideways scroller remains. Markup
additions (rendered at every width):

- the team name wrapped in `<strong class="log-team">`;
- an empty cell shows «— нет ответов»;
- an answer the game would accept is followed by `<span class="log-ok" aria-label="верно">✓</span>`.
  "Would accept" is **`level.find_question_by_answer(answer).present?`** — the method the game's own
  crediting uses (`strip.upcase`, quiz questions skipped; see `Level#find_question_by_answer` and
  `GamePassing#correct_answer?`). No second matching rule is written. `LogsController#show_full_log`
  already preloads `Level.includes(:questions => :answers)`, so the check adds no per-cell query;
  `spec/requests/full_log_queries_spec.rb` must stay flat.

Desktop keeps the grid. The `.table-wrap` is the live region.

**Live channel (`logs/show_live_channel`).** `table#livechannel` gains `table--compact`: labels
suppressed, each entry two lines — `13:07:36 · Следопыты Бишкека` / `Уровень 2: Мост — код`. Long
answers and names wrap. The `.table-wrap` is the live region; `shared/_live_status` sits above the
table.

**Results (`game_passings/show_results`).** Already cards; gains the live region and wrapping.

**Per-team level and game logs, game page, admin entries.** Plain lists; they overflow only on
long unbroken text. Fixed by two rules, not markup:

- `.main { overflow-wrap: break-word; }` site-wide. `break-word` — not `anywhere` — so desktop tables'
  min-content widths, and therefore their column layout, do not change.
- `overflow-wrap: anywhere` inside `table--compact`, `log-matrix` on phones, and the test-run
  invite `<code>` on the game page.

## §4 Scope, i18n, tests, rollout

**In scope:** standings + interventions, live channel, full log, results (live); per-team level log,
per-team game log, game page, admin entries (overflow only).

**Out:** the games list (`/games`) — no overflow measured; its operator cell changes only through
the site-wide wrap rule, redesign deferred to E1; the adjustment form and confirm page (plain
`.field` forms, already fine); admin games console, access codes and passes, withdrawal (not
mid-game); any server-side endpoint, JSON, websocket or per-game interval; any `.feature` file.

**i18n** — new keys in all seven locales (`ru`/`en` written; `uk`/`be`/`pl`/`tr`/`ka`
machine-produced per the existing policy):

| Key | ru |
|---|---|
| `shared.live_status.updated` | «Обновлено %{seconds} с назад» |
| `shared.live_status.pause` | «Пауза обновления» |
| `shared.live_status.resume` | «Возобновить обновление» |
| `game_passings.index.level_log_button` | «Лог уровня» |
| `game_passings.index.game_log_button` | «Лог игры» |
| `logs.show_full_log.no_answers` | «— нет ответов» |
| `logs.show_full_log.accepted` | «верно» |

None carries a user-authored value, so the Turkish/Georgian suffix rule does not arise. The
`%{seconds}` key is interpolated in JavaScript; check each locale reads naturally with a number
in front of its unit.

**Tests**

- `spec/live_region_script_spec.rb` — runs the script under `node` (as
  `spec/views/countdown_spec.rb` does; **raises**, not skips, if `node` is missing) against a small
  DOM shim or fixture: swaps the region; holds on an open `<details>`, a focused field, a hidden
  document; keeps old content on a failed fetch; paused toggle persists and survives a throwing
  `localStorage`.
- Request specs, literal Russian: standings panel has «Лог уровня»/«Лог игры» and the row still
  has «(лог по уровню)»/«(лог по игре)»; `.opbar` holds Pause; full log shows «— нет ответов» for an
  empty cell, ✓ after an accepted answer (including a different-case/whitespace variant) and no ✓
  after a rejected one or a quiz level's leftover code; live screens render `data-live` and the
  status partial; query count on the full log unchanged.
- `spec/layout/operator_standings_layout_spec.rb` (seventh) — 390×680, 375×553, 1280×800, both
  themes, 12 teams incl. a long unbroken name: phone row ≤90px; Pause hit-testable at the top and the
  bottom of the scroll; every control in an opened panel ≥44px; the original log-link cells
  `display: none` on phones and visible on desktop; no page or inner sideways scroll.
- `spec/layout/operator_logs_layout_spec.rb` (eighth) — full log, live channel, level log, game log at
  390×680 and 1280×800, both themes: no page-level or inner sideways scroll on phones; team blocks
  full width on phones; long unbroken answers and team names wrap; desktop full log still a grid
  (more than one cell in a team row).
- Gates (orchestrator, each alone, fresh isolated DB): full RSpec; all layout specs;
  `bin/measure-play-screen` (the bar borrows the play screen's sticky pattern); full Cucumber;
  inherited contract 228/2325; `features/` diff empty. Before/after screenshots of the in-scope
  screens at 390 and 1280.

**CLAUDE.md** gains a short "Operator screens on a phone" note: the hidden log-link cells and why
(with the rack-test reasoning), the refresh holds, `table--compact`, and the two layout specs.

**Rollout:** one PR from `design/operator-mobile`. Commits: refresh script + spec → shared CSS
(`table--compact`, wrap rules, `.opbar`) → standings → full log + live channel → results and the
overflow-only screens → layout specs → CLAUDE.md. No migration, no gem; deploy is the owner's step.
