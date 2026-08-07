# User profiles and the games listing — design

**Date:** 2026-08-06
**Status:** approved, not yet implemented

Two independent changes, specified together because they share an i18n and testing
surface and would otherwise collide in the locale files.

1. **Profiles** — retire the dead ICQ and Jabber fields; add Instagram, Telegram,
   and per-messenger availability.
2. **The games listing** — `/games` currently shows a name and some links. Add
   start, end, status and participant counts.

Neither depends on the other. They can ship as one branch or two.

---

## Global constraints

- Rails 8.0.5.1, Ruby 3.3.12 (rbenv; not on `PATH` in non-login shells — prefix
  commands with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`).
- Baselines that must hold: **234 cucumber scenarios** (2 pre-existing
  "undefined") / **2362 steps**, and the RSpec suite green (711 examples at the
  time of writing, 6 pending).
- `features/**/*.feature` is read-only **except** for the one authorised
  amendment in §2.3. No other feature file may be touched.
- Every new user-facing string is a `t()` key present in **all four** of
  `config/locales/{ru,en,uk,ka}.yml`, with real Ukrainian and Georgian — not
  Russian copied across. Author-written game content is never translated.
- Hash rockets (`:key => value`) throughout; match the surrounding file.
- No new colour or spacing literals — tokens live in `public/stylesheets/tokens.css`.
- No asset pipeline: plain CSS in `public/stylesheets/`, no build step.

---

## 1 · Profiles: data model

### 1.1 The migration

One migration, `db/migrate/*_replace_legacy_contacts_on_users.rb`:

```ruby
class ReplaceLegacyContactsOnUsers < ActiveRecord::Migration[8.0]
  def change
    remove_column :users, :icq_number, :string
    remove_column :users, :jabber_id,  :string

    add_column :users, :instagram,   :string
    add_column :users, :telegram_id, :string

    add_column :users, :on_telegram, :boolean, :default => false, :null => false
    add_column :users, :on_whatsapp, :boolean, :default => false, :null => false
    add_column :users, :on_viber,    :boolean, :default => false, :null => false
    add_column :users, :on_signal,   :boolean, :default => false, :null => false
    add_column :users, :on_max,      :boolean, :default => false, :null => false
  end
end
```

`remove_column` with its type given is reversible, so `db:rollback` restores the
columns — **empty**. The data itself is gone. This is deliberate and was decided
explicitly: no export is taken first.

### 1.2 Why five booleans rather than one serialized column

The `users` table is entirely flat scalars. Booleans stay queryable, so "which
members of the confirmed teams are reachable on Signal?" is a `where` clause
rather than a full-table load and a Ruby filter.

The decisive argument is local: this application's one serialized column,
`game_passings.answered_questions`, is the source of its worst data-safety bug —
legacy rows raise `Psych::DisallowedClass` under Rails' safe YAML loading, and
`AnsweredQuestionsCoder` carries a 30-line comment and a rescue clause to keep
one bad row from 500ing every request that touches it. Adding a second
serialized column to a codebase already carrying that scar is the wrong
instinct.

Cost of the boolean choice: adding a sixth messenger later is a migration rather
than a data edit. That is the right trade for a list that changes every few
years.

### 1.3 Handle normalisation

`instagram` and `telegram_id` are stored as **bare handles**, so the profile can
render a working link and two users who typed the same handle differently are
stored identically.

A `before_validation` on `User` strips, for each of the two fields:

- surrounding whitespace,
- a leading `@`,
- a leading `https://`/`http://` and `www.`,
- a leading `instagram.com/` (for `instagram`) or `t.me/`/`telegram.me/`
  (for `telegram_id`),
- any trailing `/`.

Empty string normalises to `nil`, so a cleared field is absent rather than blank —
the profile view tests presence to decide whether to render a row.

No format validation beyond that. Instagram's and Telegram's own handle rules
change, and rejecting a valid handle is worse here than storing an odd one: this
is a contact note for a human organiser, not an API key.

### 1.4 Field semantics

`telegram_id` and `on_telegram` are **independent**. A player may record a handle
without ticking the box ("that is my handle, but reach me on Signal"). Nothing
derives one from the other.

---

## 2 · Profiles: application surface

### 2.1 Files changed

| File | Change |
|---|---|
| `app/models/user.rb` | normalisation callback (§1.3) |
| `app/controllers/users_controller.rb` | `profile_params` — drop `:icq_number`, `:jabber_id`; add `:instagram`, `:telegram_id`, `:on_telegram`, `:on_whatsapp`, `:on_viber`, `:on_signal`, `:on_max`. Update the comment at `:73` that enumerates the permitted list. |
| `app/views/users/edit.html.erb` | replace the two text fields; add two text fields and a five-checkbox group |
| `app/views/users/index.html.erb` | replace the two rows; render Instagram and Telegram as links, and the messenger list as one row |
| `app/views/admin/users/show.html.erb` | replace the `jabber`/`icq` rows with Instagram, Telegram and the messenger list |

The messenger group is rendered as a single labelled `<fieldset>` of checkboxes
on the edit form, and as one comma-joined row on the two read views — a row per
messenger would triple the table height for five booleans.

Rows for `instagram` and `telegram_id` render only when the value is present, so
a player who fills in neither sees no empty rows. The messenger row renders only
when at least one flag is set.

### 2.2 The captain-only precedent

`phone_number` is already rendered and edited only for captains
(`users/index.html.erb`, `users/edit.html.erb`). The new fields are **not**
captain-only — they are ordinary contact details for any player, which is what
`icq_number` and `jabber_id` were. Do not extend the captain condition over them.

### 2.3 The authorised feature amendment

`features/games/user-profile-view-and-edit.feature` is amended. **This is the
only feature file this work may touch**, and the exception was granted
explicitly by the repository owner on 2026-08-06.

Changes to that file:

- The feature description (lines 5–6) drops the `номер icq` and `jabber ID`
  bullets.
- Scenario "Просмотр профиля игрока" (line 10) drops the `Номер ICQ` /
  `Jabber ID` rows from its expected table and drops the two values from the
  `данные пользователя` step call.
- Scenario "Просмотр профиля капитана" (line 28) — same, for `данные капитана`.
- Scenarios "Редактирование профиля игрока" (line 48) and "Редактирование
  профиля капитана" (line 71) drop the two `ввожу ... в поле` lines and the two
  expected-table rows.

`features/games/steps/games_steps.rb` follows:

- `данные пользователя ...` (line 308) goes from 5 captures to 3
  (`nickname`, `password`, `date_of_birth`).
- `данные капитана ...` (line 319) goes from 6 captures to 4
  (adds `phone_number`).

Both step definitions are used **only** by this feature file — verified by
grepping all of `features/` — so the change has no blast radius beyond it.

The four scenarios must pass afterwards. The suite total stays **234**.

`CLAUDE.md`'s "The acceptance-suite rule" section is amended in the same commit
to record this exception: what was changed, when, and that it was authorised.
The rule itself is not softened. Its purpose is to make an edit a deliberate,
visible decision rather than a convenience, and a recorded exception serves that
purpose better than an unexplained diff.

### 2.4 Existing specs that must be updated

| File | Why |
|---|---|
| `spec/views/users_spec.rb:19-20, 60-61` | asserts the ICQ/Jabber labels render |
| `spec/controllers/users/update_spec.rb:11-12` | updates `icq_number` to prove an attribute is permitted — repoint at `instagram` |
| `spec/controllers/users/update_spec.rb:34` | comment enumerating the permitted list |
| `spec/requests/admin_reporting_spec.rb:107-115` | "shows contact details to a superadmin" sets `icq_number` and asserts the value renders — repoint at `telegram_id` |
| `spec/i18n_spec.rb:97-103` | see §5.2 |

---

## 3 · `Game#status`

### 3.1 The problem

The precedence **withdrawn → draft → finished → running → scheduled** exists
twice today:

- `Game.count_by_status` (`app/models/game.rb:182`) computes it in SQL, and
  carries a comment stating the order "matches how the admin console labels a
  game in its status column, **deliberately**: two admin screens disagreeing
  about what a game IS would be worse than either being wrong on its own."
- `app/views/admin/games/index.html.erb:23-33` reimplements it as an
  `if/elsif` chain.

A comment explaining that two implementations must agree is a comment doing a
method's job. The new listing would be the third copy.

### 3.2 The extraction

```ruby
  # The single source of truth for what a game IS. The predicates overlap by
  # construction -- a withdrawn game may also be finished -- so the order is
  # load-bearing, not stylistic. count_by_status must apply the same
  # precedence in SQL, and the two are pinned to each other by spec.
  #
  # paused? and editing_locked? are deliberately NOT here: a game can be
  # paused AND running, and folding either in would hide one fact in order to
  # show the other. Both are reported alongside the status, never instead of
  # it -- the same reasoning count_by_status already documents for locking.
  def status
    return :withdrawn if withdrawn?
    return :draft     if draft?
    return :finished  if author_finished?
    return :running   if started?
    :scheduled
  end
```

Consumers: the new public listing (§4), `admin/games/index.html.erb` (its
`if/elsif` chain is replaced by a `case game.status`), and
`Game.count_by_status`, whose SQL stays as it is — SQL counting is correct there
and `Game.started`/`Game.notstarted` load every row, which the existing comment
already warns against building counts on.

A spec asserts `count_by_status` and `#status` agree: for a set of games covering
all five states, the tally of `#status` values equals the hash
`count_by_status` returns. That is the guard the comment was standing in for.

---

## 4 · The games listing

### 4.1 Scope

`app/views/games/_list.html.erb`, rendered by `games/index.html.erb` for both
`/games` and `/games?user_id=N`.

### 4.2 What each row shows

| Column | Scheduled | Running | Finished |
|---|---|---|---|
| Name | link (unchanged) | link | link |
| Status | scheduled tag | running tag (live) | finished tag |
| Start | `starts_at` | `starts_at` | `starts_at` |
| End | — | elapsed since start | `author_finished_at`, plus duration |
| Participants | `7 / 20` | `7 / 20` · 5 играют | `7 / 20` · 5 играли |

Withdrawn and draft games carry their own tags and are only ever visible to
their author or a superadmin — `Game.visible` already scopes the listing, and
`games_controller#index` re-applies it for the `user_id` branch.

A paused game shows the running row plus a paused marker beside the status tag,
never instead of it (§3.2).

**Status wording must match the admin console.** `admin.games.index` already has
translated labels for all five states (`withdrawn`, `draft`, `finished`,
`running`, `scheduled`) plus `locked`. The listing gets its **own keys** under
its own namespace — reaching across namespaces to reuse another screen's keys
couples two screens that should be free to word things differently — but the
**translated values are copied verbatim** from the admin ones in all four
locales. The whole point of §3 is that these two screens never disagree about
what a game is; showing the same state under two different words would defeat
that at the last step.

**"Registered" is accepted `GameEntry` records** — `game_entries` with status
`"accepted"` — against `max_team_number`. **"Playing" is `game_passings`**, the
same number the admin console shows, so the two screens agree.

Everything is computed server-side per request. No polling endpoint, no
JavaScript. Refreshing the page updates the counts.

### 4.3 Duration

Rendered as `Xч Yм`, from `author_finished_at - starts_at` for a finished game
and `Time.now - starts_at` for a running one. A game with a nil `starts_at`
(possible — the column is nullable and `started?` treats NULL as not started)
shows no duration rather than a nonsense value.

`GamePassing#time_at_level` already formats an elapsed interval as
`"%02d:%02d:%02d"` via `seconds_fraction_to_time`. That helper carries a
standing `TODO: keep SRP, extract this to a separate helper`. Extract it to
`ApplicationHelper` and use it for both, resolving the TODO rather than adding a
third formatting of elapsed time.

### 4.4 Preloading

The listing must issue a bounded number of queries regardless of how many games
it renders. `game_entries` and `game_passings` counts are the risk: rendered
naively they are two queries per game.

Use `counter`-style preloading via a single grouped count per association,
keyed by `game_id`, computed once in `GamesController#index` and passed to the
partial — not `includes`, which would load every entry and passing row into
memory to count them.

**This gets an explicit query-count spec**, not a promise. Two N+1s reached
review on the quiz branch this session: one from a missing preload, and one from
calling a scope on an already-preloaded association, which re-queries. The
second is the trap here — `game.game_entries.with_status("accepted").count`
re-queries even when `game_entries` is already loaded, because `with_status` is
a scope and a scope always builds a new relation. (`GameEntry` has
`with_status`; there is no `accepted` scope, only an `accept!` instance method.)

### 4.5 The frozen features that must keep passing

Three feature files navigate to this listing via the link "Все игры домена" and
then click a link inside it:

- `features/games/confirmed-teams-preview.feature:23`
- `features/logs/live-channel.feature:27,30,31,42`
- `features/logs/log.feature:95,98`

Constraints that follow: every existing link keeps its exact text and stays
present under the same conditions; no new link text may be a substring collision
with an existing one, since Capybara's `click_link` raises on ambiguous matches;
and no new element may wrap an existing link in a way that changes what
`иду по ссылке` resolves to.

New information is added **around** the existing links, never substituted for
them.

### 4.6 Presentation

The listing is currently a `<ul class="game-list">`. It becomes a
`<table class="table--cards">`, the responsive component the admin console
already uses: column headers in a `<thead>`, hidden below 48rem while each
`<td>` grows a `data-label`. That component exists, is already used by three
screens, and handles the narrow-viewport case this row of five columns would
otherwise fail.

Wrapped in `.table-wrap` (`overflow-x: auto`) — game names have no length
validation, and one long unbroken name would otherwise scroll the whole page
sideways.

---

## 5 · Testing and i18n

### 5.1 Tests

**RSpec — new:**

- `Game#status` returns each of the five values, including that a withdrawn
  *and* finished game reports `:withdrawn`, and a paused running game reports
  `:running`.
- `Game#status` and `Game.count_by_status` agree across a fixture set covering
  all five states.
- Handle normalisation: `@user`, `https://instagram.com/user`, `t.me/user`,
  `www.instagram.com/user/` and `  user  ` all store `user`; `""` stores `nil`.
- The listing issues a bounded number of queries for 1 game and for 10 —
  the count must not grow with the number of games.
- The listing renders the right participant numbers in each of the three states.

**RSpec — updated:** the five files in §2.4.

**Cucumber:** 234 scenarios, 2362 steps. The four amended profile scenarios are
re-verified against the new form; the other 230 are untouched.

### 5.2 i18n

**Removed** (6 keys × 4 locales): `users.edit.icq_label`,
`users.edit.jabber_label`, `users.index.icq_label`, `users.index.jabber_label`,
`admin.users.show.jabber`, `admin.users.show.icq`.

**Added** (× 4 locales): labels for Instagram and Telegram on the edit form, the
profile view and the admin view; a heading for the messenger group; five
messenger names; and for the listing — column headers for status, start, end and
participants, the five status tag labels, the paused marker, and the
"играют"/"играли" participant suffixes.

**The `known_legitimate_duplicates` trap.** `spec/i18n_spec.rb:94` fails when an
English value is byte-identical to its Russian one, to catch keys nobody
translated. It carries an allowlist at line 95, and **four of its ten entries are
keys this work deletes** — those entries must be removed with them.

More importantly, the new messenger labels are **brand names** — Instagram,
Telegram, WhatsApp, Viber, Signal, MAX — identical in all four locales by
design. Every one of them will trip that guard on its first run. They must be
added to `known_legitimate_duplicates`, for exactly the reason
`admin.users.show.icq` is already there. This is expected, not a translation
failure.

Ukrainian and Georgian get real translations for everything that is not a brand
name. `config.i18n.fallbacks` sends untranslated keys to `:ru`, so a missing key
degrades rather than printing `translation missing:` — but a key that renders
Russian to a Georgian speaker is still a defect here, because these are new keys
being written from scratch rather than the known-untranslated backlog.

---

## 6 · Out of scope

- A planned end time for games. Considered and rejected: it needs a column, an
  authoring field, validation against `starts_at`, and it can disagree with when
  the game actually ends. The listing shows the actual end and the duration.
- Auto-refreshing participant counts. Considered and rejected: `/games` is
  public and unauthenticated, so every idle browser would poll. Counts are
  current at page load.
- Handles for each of the five messengers instead of availability flags.
  Considered and rejected as a much longer form for a marginal gain.
- Team history on the admin user page — `users.team_id` is one column, so the
  schema keeps no record of previous teams. Already documented in
  `admin/users/show.html.erb`.
- Any other messenger. The five are Telegram, WhatsApp, Viber, Signal, MAX.
