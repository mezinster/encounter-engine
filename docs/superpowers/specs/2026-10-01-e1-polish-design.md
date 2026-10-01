# E1: app-wide polish — encounter-engine

**Status:** approved in conversation 2026-10-01; this is the written spec for review.
**Date:** 2026-10-01
**Programme:** wave item **E1** of the 2026-09 visual/UX wave (after B+F #182, A+G #183/#184, E2 #185,
asset versioning #186, D #187). One PR, three parts (owner's choice), executed in lanes.

## Goal

Finish the public and everyday surfaces: every screen has its own browser-tab title; the app has a
real home-screen icon; nothing a screen-reader user needs is silent; every list says something when
it is empty and, where the viewer can act, what to do next; every checkbox and radio is a full-size,
consistently styled row. Plus the follow-ups the E2 and D reviews deferred.

Success: both suites green with the inherited contract at 228/2325 and `features/` untouched; each
item below pinned by a request/view/layout example; desktop and phone visually unchanged except
where this spec changes them.

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Packaging | One PR, three parts, executed in lanes | Owner's choice |
| Title format | «Page — Game · Активные городские игры»; site name alone where a page has no title | Most specific first, so phone tabs show what matters; `layout.title` stays the suffix/fallback, which `spec/views/layouts_spec.rb` pins |
| Home-screen icon | Amber map pin with a keyhole on the dark background | Owner's pick; reads at 16px, says "find the code in the city" |
| Empty states | Card with title + one sentence + one quiet link where the viewer may act | Owner's pick; never a filled `.btn--go` |

## Part 1: identity and accessibility

### 1.1 Page titles

`ApplicationHelper#page_title(page, game: nil)` — called at the top of a view — stores the parts via
`content_for(:title)`; both layouts render
`<title><%= title parts joined as "page — game · site" %></title>`, falling back to
`t("layout.title")` alone when no view set one. The page part reuses the screen's existing heading
key where one exists, else a new key under `titles.*` (all seven locales). Game names are
author-written: rendered verbatim (escaped), never through `t()`. Every player, operator and author
screen gets one (about 25 views); the admin consoles share «Администрирование». The home page keeps
the bare site name.

### 1.2 Home-screen icon, manifest, theme colour

- One SVG source, `public/icons/pin.svg`: an amber (`#fbbf24`, the dark `--go`) map pin with a
  keyhole in its head, on `#12100e` (dark `--bg`).
- Rendered once (chrome-headless, committed): `public/apple-touch-icon.png` (180×180),
  `public/icons/icon-192.png`, `public/icons/icon-512.png`, `public/icons/icon-maskable-512.png`
  (artwork inside the maskable safe zone), `public/icons/favicon.svg`. The existing
  `public/favicon.ico` stays as the fallback.
- `public/site.webmanifest` (static): `name` «Активные городские игры», `short_name`
  «Городские игры», `background_color`/`theme_color` `#12100e`, `display: "browser"` — deliberately
  not `standalone`: logout is a plain link (`GET /logout`, see CLAUDE.md) and a standalone shell
  without browser chrome would strand users on some flows.
- Both layouts link icon, apple-touch-icon and manifest through `versioned_asset`.
- `<meta name="theme-color">`: one tag; `public/javascripts/theme.js` sets its `content` from the
  active theme on load and on every toggle (`#12100e` dark, `#faf8f6` light). Media-query variants
  are not used: the theme is chosen client-side (localStorage, then `prefers-color-scheme`), so the
  server cannot know it and a media query would ignore the in-app toggle.

### 1.3 Announcements

- Play screen (`game_passings/show_current_level.html.erb`): the correct-answer message gets
  `role="status"`; the wrong-answer and rejected messages `role="alert"`. Their text stays rendered
  in place (`features/game-passing/stepping-next-level.feature:26-27`).
- `sessions/new`: drop the view's own `<p class="error"><%= flash[:error] %></p>` — the layout's
  flash loop already renders the same `flash.now[:error]` with `role="alert"`, so the message showed
  twice. The frozen login scenarios assert the text, which the layout still renders.
- The refresh stamp (`shared/_live_status`) stays **not** live: announcing «Обновлено 12 с назад»
  every second would drown a screen reader.

### 1.4 Headings

- Standings (`game_passings/index.html.erb`): the bare title text becomes an `<h1>` with the same
  text.
- Signed-in home: card and empty-state titles become `h2` under the `h1` (today `h3`, skipping a
  level). Guest page unchanged.

### 1.5 Follow-ups

- Standings panel button: a visually-hidden team name inside the summary, so it reads
  «Вмешательство: Адреналин»; and in `forced-colors: active` the clipped label is hidden properly
  (not relying on `color: transparent`, which forced colours override).
- Generic file thumbnail (`game_files/_file_table.html.erb`): the text label becomes a file glyph
  with the label visually hidden — `spec/views/game_files/file_table_spec.rb` keeps asserting the
  text; nothing wraps mid-word in tr/pl/ka any more. `styleguide_layout_spec` re-measures it.
- `logs/show_full_log.html.erb`: a space between «Верный код:» and the code in the single-code
  branch (the many-code branch and the level/game logs already have one).
- `index/_upcoming.html.erb`: the hard-coded «·» moves into the translated string.
- `config/locales/be.yml`: `date.abbr_month_names` overridden in lowercase (rails-i18n's are
  capitalised: «12 Кас, 21:00»).
- `index.index.title`: unused since E2 — removed from all seven locales.
- `activerecord.attributes.game_run.max_team_number` and `.ordinal` in all seven locales, the noun
  agreeing in gender with the predicates it is paired with (CLAUDE.md, "a validation message is a
  predicate"), so the open-run alert no longer reads «Max team number не может быть пустым».
- Live channel and full log: the pager moves inside the `[data-live]` region, so the page count
  refreshes with the rows.

## Part 2: empty states

`shared/_empty_state` (locals `title:`, `text:`, optional `action: [label, path]`, `heading:` h2|h3
for correct heading order) renders a quiet `.card.empty-state`; its action is a plain link, never a
filled button. One rhythm rule in `screens.css`; a specimen on `/admin/styleguide`, measured by
`spec/layout/styleguide_layout_spec.rb` (both themes: inter-block gap, no overflow, link ≥ 44px).

At each site, an empty collection renders the card **instead of** the header-only table or empty
list, keeping every wrapping container and id (`#mygames`, the fieldsets, `[data-live]` regions):

| Screen | Title / sentence (ru) | Link — only when the viewer may act |
|---|---|---|
| Dashboard «Мои игры» | Игр пока нет | «Создать игру» |
| Games list `/games` | Игр пока нет | — |
| Dashboard upcoming / finished | one line inside the fieldset | — |
| Teams list | Команд пока нет | «Создать команду» (signed in, no team) |
| Game page: registrations | Заявок пока нет | — |
| Dashboard teams-by-game | Команды ещё не зарегистрированы | — |
| Levels list (author) | Уровней пока нет | «Добавить уровень» |
| Standings | Команды ещё не начали | — |
| Live channel | Ответов пока нет | — |
| Results | Финишировавших пока нет | — |
| Level log / game log | Ответов нет | — |
| Game files | Файлов пока нет | — (upload form is on the page) |
| Access codes / passes | Кодов пока нет | — (generate form is on the page) |
| Translation proposals | Предложений нет | — |
| Admin entries | replaces the bare «—» | — |
| Admin games / users / teams / audit, users list, answers | one line each | — |
| Hints | existing text, moved onto the partial | — |

On the live screens the card sits inside the `[data-live]` region, so the first answer replaces it
on the next refresh. About 40 keys under `empty_states.*`, all seven locales. Before each swap the
implementer checks the frozen features for a `не должен видеть` the new text could trip and for any
step relying on the empty table existing.

## Part 3: checkbox and radio rows

Every converted control becomes a wrapping `<label class="check"><%= control %> <span>Label</span></label>`
(44px row, the whole row a target; the CSS and styleguide specimen exist):

| Where | Today | Change |
|---|---|---|
| `games/new`, `games/edit`: locale list (incl. the disabled primary) | bare `<label>` | `label.check` per locale |
| `games/new`, `games/edit`: «Черновик?», points | checkbox + **sibling** `f.label` | wrapping `label.check`, **identical** text |
| `options/index`: correct | sibling `f.label` | wrapping `label.check` |
| `users/edit`: five messenger checkboxes | bare `<label>` | `label.check` |
| `levels/new`, `levels/edit`: any-code / all-codes radios | bare `<label>` | `label.check` |
| `translation_runs/new`: locales | bare `<label>` | `label.check` |
| `game_files/_file_table` picker checkbox | **no label** | `label.check` with the file name visually hidden |

Left alone: the play screen's quiz options (`.quiz-option`, its own component) and the drawer's
technical checkbox.

**Frozen risk:** `features/games/game-draft.feature:13`, `edit-game-profile.feature:32,45` and
`hide-draft-game.feature:15,29` tick/untick it as «Черновик» (three) and «Черновик?» (two) — Capybara matches label text by substring, so both resolve to the label «Черновик?». Capybara resolves a checkbox from a
wrapping label or a `for=`-associated one; the wrapping label keeps exactly `games.form.is_draft`
and the checkbox keeps its `id`. A request example pins the association; the frozen scenarios are
the real test.

Add `.field > label.check.is-invalid` (error colour) so an invalid checkbox reads as invalid.

## Tests

- Part 1: a helper spec for `page_title` (parts, fallback, escaping a game name with `<`); request
  examples for a representative title per area (player, operator, author, admin); a request example
  that both layouts link icon/apple-touch-icon/manifest with `?v=` digests and that the manifest file
  parses as JSON with the stated fields; a node or view check that `theme.js` sets `theme-color` for
  both themes (`theme.js` is run under node with a minimal fake, raising if node is missing, as the
  other script specs do); request examples for the play-screen roles, the single login error, the
  standings `<h1>`, the signed-in home `h2`s, «Верный код: », the `·` key, be lowercase abbreviated
  months, the `game_run` attribute nouns via a real failing validation; the panel summary's
  accessible text includes the team name.
- Part 2: one request example per screen — empty renders the card with literal Russian, non-empty
  renders the table; the action link present only for a viewer allowed to use it; the styleguide
  layout measurement.
- Part 3: per converted form, every checkbox/radio (except quiz options and the drawer) is inside a
  `label.check` with its literal text; the picker checkbox's accessible name is the file name; the
  «Черновик?» association.
- Gates (orchestrator, each alone, fresh isolated DB): full RSpec; all layout specs; full Cucumber;
  inherited contract 228/2325; `features/` diff empty. Screenshots of the icon (16/180/512), a few
  empty states, and the converted forms.

## Rollout

One PR from `design/e1-polish`. Lanes: part 1 first (titles touch most views and both layouts);
then parts 2 and 3, in parallel only where their files are disjoint — `games/_list`, `games/new`
and `games/edit` are shared and run one after another. Mutation checks only with no other writer
in the worktree (CLAUDE.md records why). No migration, no gem; about 60 new keys × 7 locales.
CLAUDE.md gains short notes on `page_title`, the manifest/theme-color choice and the empty-state
partial. Deploy is the owner's step.

## Out of scope

C (exit confirmation, pending the owner's feature-file decision); a standalone PWA; any redesign of
the games list beyond its empty state.
