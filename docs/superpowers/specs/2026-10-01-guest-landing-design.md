# Guest landing: a home page that says what this is — encounter-engine

**Status:** approved in conversation 2026-10-01; this is the written spec for review.
**Date:** 2026-10-01
**Programme:** wave item E of the 2026-09 visual/UX wave, split into **E2** (this spec — the guest
landing) and **E1** (app-wide polish: per-page titles, home-screen icon/manifest/theme-color, empty
states elsewhere, the generic-thumbnail icon, live-region roles on the play screen's own flashes and
`sessions/new`, adopting `.check` rows). Builds on #182 (foundations), #183 and #184.

## Goal

The frozen acceptance contract states the intent in the original authors' words —
`features/index-page/index-page.feature`: *«Чтобы посетители сайта видели что-нибудь осмысленное как
только заходят на сайт»* ("so visitors see something meaningful as soon as they arrive"). Today `/`
is an `<h2>`, a link and the full games table, which on a phone is an empty-looking page.

The new home page serves **both audiences, players first**: a first-time visitor understands what an
encounter game is and finds a game to join; organizers get a smaller section further down. A signed-in
player sees the same page without the explanation, with their own team's status on each game.

Success: both suites green with the inherited contract at 228/2325 and `features/` untouched; the
guest view has exactly one filled `.btn--go`; the layout spec passes in both themes at 390×680 and
1280×800; every state in §3 has a request example pinned with literal Russian.

## The design source

Designed on the Superdesign canvas (project `d2acedc0-5ed3-40a0-87ae-15b28cce841c`,
https://superdesign.dev/teams/9309852a-c600-4c0e-b7f1-021c835ff017/projects/d2acedc0-5ed3-40a0-87ae-15b28cce841c),
phone width, dark theme, `gemini-3.1-pro`, constrained to `.superdesign/design-system.md` and the
real stylesheets/layout as context:

| Draft | Id | Role |
|---|---|---|
| A — base | `5813e9cc-8400-4951-920e-24e015659eb4` | explored |
| **B — games first, v2 (with C's timeline)** | `7eaa33ad-eb0a-4a08-bb6c-504f86953069` | **chosen guest view** |
| C — explainer-led | `e90fff0b-6094-4a4f-9b23-b6dcb0193048` | timeline borrowed into B |
| **Signed-in — captain** | `659ef6ac-23c9-4136-94c3-94108ceeb9d0` | **chosen signed-in view** (hand-authored, imported — the account ran out of generation credits) |

The drafts are the visual reference; this spec is the contract where they differ. Known differences,
all deliberate: the guest card has **no** button (§3.1, the one-filled-button rule); the signed-in
statuses use the app's **existing** wording (§3.2), not the draft's «Команда принята».

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Audience | Both, players first | Owner's call |
| Signed-in view | Same page, no hero/timeline/organizers; team status per game | Regulars don't re-read the explanation; one page, two depths |
| Visual direction | B (games first) + C's timeline | Owner's pick from three drafts |
| Next-game card action for a guest | **None** | `components.css`: `.btn--go` is "the only filled warm control on a screen"; the hero already has it |
| Captain's actions | Reuse `shared/_game_entry_controls` | The dashboard already renders it; one source of truth for who may do what |
| Manual deep links | Per-locale anchor keys, spec-verified | Heading ids differ by language |
| Desktop | Single column capped at ~44rem | The page reads top to bottom; no second column |

## §1 Which games appear, and in what order

A new query object, `UpcomingGames` (`app/services/upcoming_games.rb` — this app keeps plain query/service classes in `app/services/`; there is no `app/queries/`), built from `Game.visible`
(which already excludes drafts, withdrawn games and test runs), loaded with `includes(:runs)` in one
query and classified in memory with `Game#status`:

1. **Running** (`:running`) — compact rows tagged «Идёт сейчас» (`.tag--live`), first.
2. **Next game** — the earliest `:scheduled` game by `starts_at`: the prominent card.
3. **Other scheduled** — compact rows, by `starts_at`.
4. **Code-gated** (`:available`, i.e. `pass_required?`) — rows with no date.

Excluded: `:finished`, `:draft`, `:withdrawn`. **At most 4 rows** across groups 1, 3 and 4 (in that
order), plus the card; everything else through «Список игр», which stays a link to `games_path`
under the rows.

**Registration tag (guest view, and signed-in when the team has no live entry):** «Регистрация
открыта» (`.tag--live`) only when the game is `:scheduled` **and** `can_request?` **and** its
`registration_deadline` is nil or in the future; otherwise «Регистрация закрыта» (plain `.tag`). The
card's «Команд: N из M» uses the existing `game_team_counts` helper (current-run counts), so the home
page agrees with the games list.

**Empty state:** when no game is running, scheduled or gated, the section is one quiet `.card`:
«Сейчас игр не запланировано», one sentence pointing to the full list (which includes past games),
and the «Список игр» link — so the frozen scenario still finds it.

`UpcomingGames#call` returns a value object: `running`, `next_game`, `scheduled`, `gated` (rows
already limited), and `counts` (the team counts for every game it returns). Two queries total
(games+runs, team counts), independent of how many games exist.

## §2 The static sections (guest view only)

**Hero.** `<h1>` «Городские игры: найди код раньше всех», one line «Команды ищут коды по всему
городу — с телефона.», then two actions: «Зарегистрироваться» (`.btn.btn--go`, `signup_path`) and
«Как играть» (`.btn.btn--quiet`, `#how-to-play`).

**How to play** (`<section id="how-to-play">`). A vertical timeline, new `.timeline` block in
`screens.css`: three items, each with a number in a small circle outlined in `--go` sitting on a thin
connecting line in `--border-input`, a title and one sentence:
1. «Зарегистрируйтесь» — «Нужны только имя и e-mail; пароль придёт письмом.»
2. «Соберите команду» — «Создайте команду или вступите в неё; капитан записывает команду на игру.»
3. «Играйте с телефона» — «В день игры откройте игру: задание, подсказки и поле для кода — на одном экране.»
Then one link «Подробнее в руководстве» to `manual_path` + the **player-chapter anchor** (§4).

**For organizers.** A `.panel`: heading «Проводите игры в своём городе», five bullets — «Уровни с
кодами или вопросами квиза, импорт списком», «Тестовые прогоны перед игрой», «История прогонов и
результаты», «Перевод игры на другие языки», «Платный доступ по кодам» — and the link «Руководство
организатора» to `manual_path` + the **author-chapter anchor** (§4).

## §3 Who sees what

### §3.1 The next-game card's action

| Visitor | Card shows |
|---|---|
| Guest | Name (link to the game), registration tag, date, team count. **No button.** |
| Captain | `render "shared/game_entry_controls", game_entry:, game:, team:` — apply / «Заявка подана» + «Отозвать» / «Вы зарегистрированы» + «Отказаться» / reapply / limit reached / deadline passed — identical logic and wording to the dashboard. |
| Team member, not captain | No button. If the team has no live entry: quiet line «Заявку подаёт капитан команды»; otherwise the team's status tag (§3.2). |
| Signed in, no team | No button. Quiet link «Создайте команду или вступите в неё, чтобы играть» → `teams_path`. |

**`shared/_game_entry_controls` gets classes.** Its `button_to`s render with no class today (unstyled
browser buttons, on the dashboard too). Apply and reapply get `.btn.btn--go`; recall and decline get
`.btn`. **Button text is unchanged**, so frozen Cucumber steps that press these on the dashboard are
unaffected. Text-only outcomes (limit reached, deadline passed) render as `.notice`.

### §3.2 Status tags on rows (signed-in players in a team)

From the team's `GameEntry` for the game's current run:

| Entry status | Tag |
|---|---|
| `new` | plain `.tag` «Заявка подана» (existing key `shared.game_entry_controls.applied`) |
| `accepted` | `.tag--live` «Вы зарегистрированы» (existing key `…registered`) |
| `rejected` | `.tag--danger` «Заявка отклонена» (new key) |
| `recalled`, `canceled`, none | the registration tag from §1 |

Code-gated rows: «Доступ есть» (`.tag--live`) when `gated_play_status` says the team holds a live
pass; otherwise «По коду доступа» (plain). Guests always see the registration tag (or «По коду
доступа» on a gated row). Running rows always show «Идёт сейчас».

**Status tags never wrap** (`white-space: nowrap; flex-shrink: 0`); the game name shrinks instead —
the defect caught while drafting.

**Team line** (players in a team), after «Список игр»: quiet text «Команда: «%{team}»» and a link
«Комната команды» → `team_room_path`.

## §4 Manual links, dates, i18n, desktop

**Manual anchors.** Two keys per locale, `index.index.manual_player_anchor` and
`index.index.manual_author_anchor`, each holding the kramdown `auto_ids` heading id of that locale's
«Игроку» / «Автору игры» chapter (or its translation) in `docs/manual/<locale>.md`. A spec renders
each shipped manual and fails if a stored anchor is not one of its heading ids.

**Dates.** Two new formats in all seven locales, rendered through the existing `l_with_zone` (viewer's
zone): `time.formats.home_card` — day, month name, time («12 октября, 21:00») — and
`time.formats.home_row` — short day and month, time («15 окт, 19:30»). Month names come from
`rails-i18n` (genitive where the language needs it); the plan verifies a real example date per
locale.

**i18n.** About 30 new keys, all seven locales, under `index.index.*` (hero, timeline, organizers,
empty state, member/no-team lines, team line, anchors) plus the one new tag key. `ru`/`en` written for
readers; `uk`/`be`/`pl`/`tr`/`ka` machine-produced per the existing policy. The team line carries a
user-authored name: `tr`/`ka` follow CLAUDE.md's rule (suffix on a common noun, «%{team}» adlı takım),
checked with a consonant-final and a vowel-final team name. Never Ruby-side case changes.

**Desktop** (≥48rem, drawer becomes a sidebar): the home content is capped at **44rem** wide,
centred in `.main`. No second column.

**Frozen anchors kept:** «Список игр» is a link to `games_path` (`games-list.feature`,
`index-page.feature`); «Войти» stays in the guest menu (`login.feature`); the page adds no
`/dashboard` link for guests (`dashboard.feature` — signed-in users already get one from the menu);
the page never shows «Вы не авторизованы…» (`index-page.feature`).

## §5 Testing and rollout

- `spec/services/upcoming_games_spec.rb` — grouping, order, the 4-row limit, exclusions (finished,
  draft, withdrawn, test run), and a query-count check (constant, independent of game count).
- `spec/requests/home_page_spec.rb` — guest: hero, timeline, panel present, **exactly one
  `.btn--go`**, «Список игр» → `games_path`, no `/dashboard` link; signed-in: those three absent;
  one example per §3 state (captain ×6 control states, member, no team, gated live/not); running
  first; empty state with «Список игр». Literal Russian throughout.
- `spec/requests/game_entry_controls_classes_spec.rb` (or within the dashboard spec) — the
  dashboard's buttons now carry `.btn` / `.btn--go` with unchanged text.
- `spec/i18n_home_spec.rb` — the per-locale manual anchors exist; the two date formats render a real
  example in every locale; the tr/ka team line with consonant- and vowel-final names.
- `spec/layout/home_layout_spec.rb` — the **sixth** layout spec: both themes, 390×680 and 1280×800 —
  no horizontal overflow, every `.btn`/link in the content ≥44px, status tags on one line, timeline
  circles centred on the line, content ≤44rem at desktop.
- Gates (orchestrator, each alone, fresh isolated DB): full RSpec; all six layout specs; full
  Cucumber; inherited contract 228/2325; `features/` diff empty. Before/after screenshots: home (guest
  + signed-in captain) both themes 390 and 1280, and the dashboard (its buttons change).
- One PR from `design/guest-landing`. Commits: query object → signed-in statuses + the partial's
  classes → guest sections + keys → layout spec → CLAUDE.md. No migration, no new gem.

## Out of scope

- E1 (per-page titles, icons/manifest, other empty states, the thumbnail icon, live regions, `.check`
  adoption).
- D (operator on a phone); C (exit confirmation, pending a feature-file decision).
- Any `.feature` file.
