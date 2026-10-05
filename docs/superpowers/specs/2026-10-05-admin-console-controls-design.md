# Superadmin console: streamlined controls — design

**Date:** 2026-10-05
**Status:** approved in conversation, section by section; this document awaits the owner's review
**Approach chosen:** hybrid (option 3 of 3) — a page per game where controls pile up, lighter fixes elsewhere

## 1. Why

The superadmin console grew one control at a time, each placed wherever its own
feature landed. The result, surveyed 2026-10-05:

- **`/admin/games`** — every row's last cell holds up to six buttons (edit,
  entries, withdraw/restore, unfinish, lock/unlock), a set-author form, an
  open-run form with three inputs, and delete. Twenty games is ~200 controls in
  one table.
- **`/admin/users/:id`** — grant/revoke superadmin, grant/revoke operator,
  delete, anonymise and move-to-team in one undifferentiated `.game-control`
  row: reversible and irreversible actions side by side.
- **`/admin/teams`** — delete, «Вмешательство» and a set-captain form crammed
  into each row's actions cell.
- **Navigation** — no admin nav. The left menu links four admin screens
  (dashboard, games, users, audit); teams, settings, load test and styleguide
  are reachable only from six loose `<p>` links at the foot of the dashboard.

The owner named all four as pain points and uses the console **mostly on
desktop**. The goal is fewer, better-grouped controls: scan on lists, act on
pages, and keep destructive actions apart from routine ones.

## 2. Constraints

- **No frozen feature touches the admin console.** None of the 59 `.feature`
  files references it (it postdates the Merb port), so markup may be
  restructured freely. Behaviour is protected by 22 `spec/requests/admin_*`
  files instead, which are updated alongside.
- **No JavaScript widgets.** No Turbo, no rails-ujs. Disclosure is a native
  `<details>`; actions are `button_to`/`form_with`. `data-confirm` is inert here
  and is not added anywhere (see the existing comments in `admin/users/show`).
- **Offer only what the action accepts.** Every conditional control keeps the
  predicate it has today (`game.deletable?`, `team.deletable?`, the
  self/captain/author checks on users, `author_finished? && levels.any?` for
  open-run). Moving a control never loosens its condition.
- **Tokens and existing components only** (`tokens.css` contract, enforced by
  `spec/stylesheets/token_discipline_spec.rb`): `.panel`, `.card`, `.tag`,
  `.btn`/`.btn--go`/`.btn--danger`, `.game-control`, `.danger-row`, the facts
  classes (`.facts`, `.fact-label`, `.fact-value`) from the game page, and the
  sectioned-sheet classes from the level page.
- `admin_nav_spec.rb` pins the left menu's «Администрирование» block. It stays.

## 3. Design

### 3.1 Per-game admin page and the slim games list

**New route and action:** `resources :games, only: [ :index, :show ]` in the
admin namespace → `Admin::GamesController#show`, superadmin-only (the
controller's existing `require_authentication!`/`require_superadmin!`).

Page, top to bottom:

1. **Header** — the game's name (linking to the public `game_path`), the
   author's nickname, a status `.tag` (same mapping as today's list), and
   «редактирование закрыто» when `editing_locked?`.
2. **Facts** — `.facts` tiles: teams registered / cap, teams playing, locales,
   current run ordinal.
3. **Panels**, each a `.card` with a `.fact-label` heading; a panel, or a
   control within it, renders only when its action would accept:
   - **Состояние** — withdraw (link to `new_withdrawal_game_path`) or restore;
     lock or unlock; unfinish when `author_finished?`.
   - **Заявки** — «Заявки (N)» to `admin_game_entries_path`, and «Редактировать
     игру» unless `started?`.
   - **Автор** — the set-author form.
   - **Новый запуск** — the open-run form (starts at, registration deadline,
     max teams), only when `author_finished? && levels.any?`.
   - **Удаление** — a separated `.danger-row`, only when `deletable?`.

**Redirects return to this page.** Today these go to `admin_games_path`:

| Action | Controller |
|---|---|
| `withdraw`, `restore`, `unfinish`, `lock`, `unlock` | `GamesController` |
| `set_author`, `open_run` (success and every alert) | `Admin::GamesController` |

All of them redirect to `admin_game_path(@game)` instead, so the operator stays
where they acted. `delete` keeps its current target (the game no longer
exists), and the entries screen's back link points at `admin_game_path`.

**The list `/admin/games`** keeps its columns (name, author, locales, status,
teams). Each row's actions shrink to exactly two: «Заявки (N)» and
«Управление →» (`admin_game_path`). No forms remain in the table. The name keeps
linking to the public game page.

Query shape: the list stays at its current batched queries
(`game_team_counts`, `@pending_entry_counts`). The show page computes the same
figures for one game.

Accepted cost: lock/withdraw become two clicks instead of one.

### 3.2 User page

`/admin/users/:id`, regrouped into labelled sections in the level page's
sectioned-sheet style:

- **Header** — nickname as the title; «суперадмин»/«оператор» `.tag`s beside it.
- **Профиль** — the key/value table becomes `.facts` tiles (email, phone,
  Instagram, Telegram, messengers, date of birth, team, locale, signed up).
  «Созданные игры» stays a list beneath.
- **Роли** — the two grant/revoke toggles, each with a one-line description of
  what the role allows. Grant stays `.btn--go`; **revoke becomes a plain
  `.btn`** — it is reversible, so it is not a danger action.
- **Команда** — the move form, under its existing condition (not a captain,
  another team exists).
- **Аккаунт** — a separated danger zone: «Анонимизировать», then «Удалить»
  (`.btn--danger`), each with a sentence on what it does, each under its
  existing condition.

### 3.3 Teams list

- Each row keeps the captain picker (select + «Назначить») and «Вмешательство».
- «Удалить» moves into a per-row `<details>` «Ещё ▾», rendered only when
  `team.deletable?`, closed by default.
- The members cell shows one line: the first names, then «+N» for the rest.

### 3.4 Admin tab bar

- A partial `admin/_tabs`, rendered at the top of every admin page: Обзор,
  Игры, Пользователи, Команды, Журнал, Настройки, Нагрузочный тест, Стайлгайд.
  The current section carries `aria-current="page"` (game/entries pages mark
  Игры; user pages mark Пользователи; adjustment pages mark Команды). One row;
  on narrow screens it scrolls inside itself rather than wrapping or widening
  the page.
- **A partial, not a layout.** There is no admin base controller, and a
  `layout` line in ten controllers is no tidier than one render line per view.
  The guarantee is `admin_tabs_spec.rb`, which requests every admin GET page and
  fails if one lacks the bar — the same shape as `assets_versioned_spec.rb`.
- The dashboard's six footer links are removed; so are per-page «назад» links
  whose only target was a sibling admin page.

## 4. Testing

- **Request specs**
  - New `admin_game_page_spec.rb`: each panel's presence under its condition
    (restore only when withdrawn, unfinish only when author-finished, open-run
    only when finished with levels, delete only when deletable), the list's two
    actions per row, superadmin-only access.
  - Existing specs asserting redirects to `admin_games_path` for the actions in
    §3.1 are updated to `admin_game_path`.
  - Structure examples for the user page's sections and the teams list's
    disclosure.
  - New `admin_tabs_spec.rb`: every admin GET page renders the bar with the
    right `aria-current`.
- **Layout** — `spec/layout/admin_console_layout_spec.rb` (the eleventh),
  both themes, 1280×800 and 390×680: list rows hold exactly two buttons; every
  control on the game page and user page is ≥44px tall; the tab bar is one row
  and causes no page overflow; the teams «Ещё» disclosure is closed by default.
- **Mutation checks** on the tab-bar guard, the delete-only-when-deletable
  condition, and the closed disclosure; each must go red when broken.
- **Gates** per PR: full RSpec, full Cucumber (238 / 2386 unchanged — no
  `.feature` file involved), all layout specs, then CI.

## 5. Translation keys

All seven locales, leaf count measured before and after, CLAUDE.md updated:

- **Added:** panel labels, tab names (reusing existing title keys where they
  exist), «Управление →», «Ещё», role and account descriptions, the «+N»
  members line.
- **Removed:** the dashboard footer-link keys and «назад» keys left unused.
- `uk`, `ka`, `be`, `pl`, `tr` stay machine-translated and unreviewed, as their
  headers already state.

## 6. Superdesign

One round, for the per-game admin page only: a reproduction of the current
games list as the baseline, then two variations of the new page (~70–95
credits at the rates observed). The user page, teams list and tab bar reuse
built patterns and need no generation. If credits run short, the page is
authored by hand and imported with `import-design-draft`, which costs none.

## 7. Delivery

Three PRs, in order, each merged only after the owner's approval:

1. **Tab bar + dashboard** — `admin/_tabs`, `admin_tabs_spec.rb`, footer links
   removed. Small, and every later page renders it.
2. **Per-game admin page + slim list** — §3.1, the Superdesign round, the
   redirect changes, the layout spec.
3. **User page + teams list** — §3.2, §3.3, layout examples added to the same
   spec file.

## 8. Out of scope

- The audit log, settings, load-test and styleguide pages beyond receiving the
  tab bar.
- Any change to what an action permits; only where its control is shown.
- A confirmation step for destructive actions (needs JavaScript or an extra
  page per action; tracked separately as the deferred "C" item).
