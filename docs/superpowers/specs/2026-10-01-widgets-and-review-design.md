# Widgets and review: native date and nickname inputs, translation review, full-sentence errors — encounter-engine

**Status:** approved in conversation 2026-10-01; this is the written spec for review.
**Date:** 2026-10-01
**Programme:** second sub-project (A+G) of the 2026-09 visual/UX wave. The first, UX foundations
(`2026-09-30-ux-foundations-design.md`, PR #182), shipped the type scale, the form system,
`FieldErrorMarkup` and `/admin/styleguide`; this one builds on all four. Remaining after this:
E (public face), D (operator on a phone); C (destructive actions behind a confirm) stays deferred
pending a feature-file decision.

## Goal

Retire the last Merb-era widgets and finish two half-built surfaces, without visual regressions and
without touching the frozen acceptance contract:

1. The game form's **Dynarch calendar** — light-only gif chrome on a dark-first theme, Russian in
   every locale, opened by a "..." button — becomes the browser's native `datetime-local` input,
   and the form says which timezone the time is in.
2. The invitation page's **jQuery autocomplete** becomes a native `<datalist>`.
3. The **translation review** page, whose `.proposals` / `tr.flagged` / `ul.flags` hooks have no
   CSS at all, becomes readable, and its flagged proposals become visible at a glance.
4. **Full-sentence validation messages** stop having a field name bolted to the front
   ("Nickname Вы не ввели имя", "Название Вы не ввели название").

Success: both suites green, the inherited contract at 228 / 2325, `features/` untouched; about
3,200 lines of vendored JavaScript, CSS and gif chrome deleted; the guards in §5 red on the
regressions they exist for.

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Date input | `datetime_local_field`, `:include_seconds => false` | Native picker in the user's language and theme; server parsing unchanged |
| Timezone | **Show** the zone under both date fields | `datetime-local` carries no zone; the app already uses the user's zone per request, invisibly |
| Per-game timezone | **Out of scope** | A model change (column, parsing, display everywhere) — its own sub-project if wanted |
| Autocomplete | `<datalist>` with the same nickname list | No new exposure; escaping by the tag helper instead of a hand-built JS context |
| Translation review | **Restyle in place** (table, header, `table--cards`) | Specs assert text and paths only, so markup is free; smallest change that fixes it |
| Error-message reach | **All** full-sentence fields (18 across 7 models) | One consistent rule rather than fixing signup alone |
| Sentence-format safety | A field drops its name only if **every** message it can produce is a sentence, enforced by spec | Otherwise a stock Rails predicate ("слишком длинный") would render with no noun |

## §1 Date fields and the timezone hint

### §1.1 The input

In `app/views/games/new.html.erb` and `app/views/games/edit.html.erb`:

- `f.text_field :starts_at` → `f.datetime_local_field :starts_at, :include_seconds => false`;
  the same for `:registration_deadline`. Without `:include_seconds => false`, Rails 7+ writes
  `2050-03-21T18:01:00` and some browsers render a seconds spinner.
- Remove the two `<input id="calendar-switch…" type="button" value="..." class="btn" />`
  buttons, the two `Calendar.setup(...)` blocks, and the `content_for :head` block loading
  `calendar.js`, `calendar-setup.js`, `calendar-ru-UTF.js` and `calendar.css`.

**The server does not change.** Rails' attribute casting already parses both the space-separated
form the frozen scenarios type (`2050-03-21 18:01`) and the `T`-separated form browsers send
(`2050-03-21T18:01`), in the request's `Time.zone` (`TimeZoneSelection`). The frozen date
scenarios (`create-game.feature:76–135`, `registration-deadline.feature`, `hide-draft-game.feature`)
run on rack-test, which submits the typed string verbatim whatever the input's `type`, and every
one of them asserts on the game profile after submit, never on the field's rendered value. So, unchanged:

| Typed in the scenario | Result |
|---|---|
| `2050-03-21 18:01` | saved, profile shows `2050-03-21 18:01` |
| `` (empty) | "Дата начала игры ещё не назначена" |
| `сёдня в полшистова` | casts to nil → "Дата начала игры ещё не назначена" |
| `2050-03-21` | midnight → `2050-03-21 00:00` |
| `1961-04-12 00:00` | "Вы выбрали дату из прошлого" |

A real browser cannot produce the last three shapes; that is fine — the server's handling of them
is what the contract pins, and it does not change.

### §1.2 The timezone hint

Under each date field, a `<p class="notice">` (already `--text-sm`, dim):

- text from a new key `games.form.timezone_hint` with one interpolation, `%{zone}`, where the
  view passes `"#{Time.zone.tzinfo.name} (UTC#{Time.zone.now.formatted_offset})"` — e.g.
  `Europe/Moscow (UTC+03:00)`. The offset is computed for *now*, so it is correct across DST.
- followed by a link to the profile edit page, `edit_user_path(current_user)` (`users#edit`, where
  the time-zone select lives — `app/views/users/edit.html.erb`; `users/index` already links to it
  the same way), with a second key, `games.form.timezone_change`.
- Both forms are reachable only by a signed-in author, but the profile link renders only when someone is signed in (view specs render the form without a user).

Two keys, all seven locales. `%{zone}` is a system identifier, not a user-authored name, so the
Turkish/Georgian suffix rule (CLAUDE.md) does not apply; the ka/tr templates still keep the
placeholder clear of case endings.

### §1.3 Deletions

`public/javascripts/calendar.js` (1,807 lines), `calendar-setup.js` (203), `calendar-ru-UTF.js`
(122), `public/stylesheets/calendar.css` (236), and the nine gifs it alone references:
`active-bg.gif`, `dark-bg.gif`, `hover-bg.gif`, `menuarrow.gif`, `normal-bg.gif`, `rowhover-bg.gif`,
`status-bg.gif`, `title-bg.gif`, `today-bg.gif`. Verified 2026-10-01: nothing outside the two game
views and these files themselves references any of them.

## §2 Invitation nicknames: `<datalist>`

In `app/views/invitations/new.html.erb`:

- Remove the `content_for :head` block (`jquery.js`, `jquery.autocomplete.js`,
  `jquery.autocomplete.css`), the `<script type="application/json" id="invitation-nicknames">`
  block, and the `$(document).ready` script. They are the page's only JavaScript.
- `f.text_field :recepient_nickname` gains `:list => "invitation-nicknames"` and
  `:autocomplete => "off"` (so the browser's own form history does not crowd out the list).
- After the field: `<datalist id="invitation-nicknames">` with one `<option value="…">` per
  nickname, built from **the same list as today** — `@all_users` minus `@current_user`, nicknames
  only. Emails stay absent; that was a deliberate security fix (the existing comment explains it)
  and is kept.
- The long comment about JSON escaping is replaced by a short one: each nickname is now an
  attribute value written by Rails' tag helper, escaped by default, so there is no JavaScript
  context to break out of — and the emails-absent reasoning is kept verbatim.

Deletions: `public/javascripts/jquery.autocomplete.js` (807 lines),
`public/stylesheets/jquery.autocomplete.css` (46). `public/javascripts/jquery.js` **stays** — the
game page and the play screen still load it.

Behaviour: suggestions come from the browser (Chrome/Firefox match anywhere in the nickname, Safari
from the start — close to the plugin's `matchContains: "word"`), on phones as the system suggestion
strip, and it works with scripts blocked. The frozen invitation scenarios type by label
("Пригласить нового участника") and are unaffected.

## §3 Translation review, restyled in place

`app/views/translation_proposals/index.html.erb` keeps its forms, buttons, paragraphs and comments.
Changes:

- `<table class="proposals">` → `<table class="proposals table--cards">`, with a `<thead>` of four
  headings — language, field, source, proposal — from four new keys under
  `translations.review.columns.*`, all seven locales.
- Each `<td>` gets the matching `data-label` (the same four keys), so the existing
  `.table--cards` collapse turns each proposal into a card on phones.
- Each `ul.flags > li` gets `class="tag tag--danger"`.

New block in `public/stylesheets/screens.css` (tokens only; the discipline spec applies):

- language and field columns narrow, `--text-dim`, `--text-sm`;
- `td.source`: `--surface-2` background, `--radius-sm`, padding, `white-space: pre-wrap` — the
  source's line breaks are content a reviewer must preserve, and they currently collapse;
- the proposal cell's textarea fills the cell (the shared input rule already sets `width: 100%`);
- `tr.flagged`: a 3px `--danger` left edge in the table layout, and the same edge on the card in the
  stacked layout — shape plus colour, never colour alone (the palette's standing rule);
- `ul.flags`: a wrapping row (`display: flex; flex-wrap: wrap; gap: var(--space-1)`) between the
  textarea and Accept;
- `.accepted strong` (the "edited" label): `--text-sm`, dim.

The page's existing request specs (`translation_views_spec.rb`, `translation_proposal_review_spec.rb`)
assert on text and paths only, and stay as they are.

## §4 Full-sentence errors without a field name

### §4.1 The switch

`config/application.rb`: `config.active_model.i18n_customize_full_message = true`. With it on, an
error's full message reads an optional `format` at
`activerecord.errors.models.<model>.attributes.<attribute>.format`; a field without one keeps the
default `"%{attribute} %{message}"`, so every predicate-style field is unaffected.

### §4.2 The fields

`format: "%{message}"` for exactly these 18, found by auditing every
`activerecord.errors.models.*.attributes.*` entry whose messages are capitalised sentences
(2026-10-01):

| Model | Fields |
|---|---|
| answer | `value` |
| game | `name`, `description`, `max_team_number`, `starts_at`, `registration_deadline` |
| game_entry | `game`, `team_id` |
| invitation | `for_user`, `recepient_nickname`, `for_user_id` |
| level | `name`, `text` |
| team | `name` |
| user | `email`, `nickname`, `password`, `password_confirmation` |

`invitation.base` needs nothing: `:base` errors already render without an attribute.

**One rewrite.** `game.starts_at.needed_to_unpublish_access` is the only predicate among these
fields' messages. It is rewritten as a sentence — first letter capitalised **by hand in each
locale** (never Ruby `.upcase`, which is locale-blind and breaks Turkish i/İ):

| Locale | Before | After |
|---|---|---|
| ru | у обычной игры дата старта… | У обычной игры дата старта… |
| en | a scheduled game needs… | A scheduled game needs… |
| uk | у звичайної гри… | У звичайної гри… |
| be | у звычайнай гульні… | У звычайнай гульні… |
| pl | zwykła gra musi mieć… | Zwykła gra musi mieć… |
| tr | programlı bir oyunun… | Programlı bir oyunun… |
| ka | ჩვეულებრივ თამაშს… | unchanged — Georgian has no letter case |

The ka message is a sentence already; the spec in §4.4 must therefore treat "starts with an
uppercase letter **or** belongs to a caseless script" as a sentence — it checks the `ru` and `en`
files, which are the two that have case and that every key must exist in.

### §4.3 Locales

The 18 `format` keys go into all seven files. Fallback to `ru` would cover the other five, but
writing them out keeps "a message key exists in every file" uniform, and `ru`↔`en` parity is
enforced anyway. `spec/i18n_spec.rb`'s "en must not be an untranslated copy of ru" check gains one
structural exemption: **a key ending in `.format` whose value is exactly `%{message}`** — a rule,
not 18 allowlist entries.

Before → after, in the summary (`error_messages_for`, which uses `full_messages`):

| Form | Before | After |
|---|---|---|
| Signup | Nickname Вы не ввели имя | Вы не ввели имя |
| New game | Название Вы не ввели название | Вы не ввели название |
| Invitation | Recepient nickname Вы не ввели имени пользователя | Вы не ввели имени пользователя |

The inline `.field-error` from #182 already shows the bare message, so summary and inline now agree.

### §4.4 The safety rule

A field may drop its name only if **every** message it can produce is a sentence; otherwise a
default predicate from `rails-i18n` (a future `length` validator's "слишком длинный") renders with
no noun at all. New `spec/i18n_sentence_messages_spec.rb`, for every `<model>.<attribute>` whose
`format` is `%{message}`, in `ru` and `en`:

1. every message key under that field is a sentence (first character `\p{Lu}`);
2. every validator on the field (`Model.validators_on(attr)`) maps to a message key that exists
   there — presence → `blank`, uniqueness → `taken`, format → `invalid`, confirmation → `confirmation`,
   inclusion → `inclusion`, length → the bound it declares (`too_short`/`too_long`/`wrong_length`),
   numericality → `not_a_number` plus each comparison option it declares.

Mutation-tested: a `length` validator added to `User#nickname` with no message must fail it, naming
the field and the missing key; lower-casing one `ru` sentence must fail it.

**Frozen contract.** Every frozen assertion on these messages ("Вы не ввели название",
"Пользователь с таким адресом уже зарегистрирован", "Вы не ввели вариант кода", …) is a substring
check on the page, satisfied with or without a prefix. Any RSpec example pinning the *prefixed*
form is updated in the same commit.

## §5 Guards, verification, rollout

### §5.1 Default RSpec

- `spec/requests/game_dates_form_spec.rb`: both date inputs are `type="datetime-local"` on new and
  edit; both forms show the hint with the request's zone and the change link; no calendar
  `<script>`/`<link>` remains; a **browser-shaped** value `2050-03-21T18:01` saves and the profile
  shows `2050-03-21 18:01` (the frozen scenarios only send the space form — this is the one browser
  behaviour this change introduces).
- `spec/requests/invitation_datalist_spec.rb`: the field's `list` points at the datalist; the
  current user is absent from it; no e-mail address of any user appears in the page; a nickname
  `x" onmouseover="alert(1)` and one containing `</datalist>` render as text inside a `value`
  attribute; no `jquery` script tag.
- Translation review request spec: header present; every `<td>` has `data-label`; a flagged
  proposal's row has `flagged` and its flags `tag--danger`.
- `spec/i18n_sentence_messages_spec.rb` (§4.4), mutation-tested.
- `spec/assets_retired_spec.rb`: no file under `app/` or `public/` references `calendar.js`,
  `calendar-setup.js`, `calendar-ru-UTF.js`, `calendar.css`, `jquery.autocomplete.js`,
  `jquery.autocomplete.css`, or any of the nine gifs — so a later revert of a view cannot quietly
  reintroduce a `<script src>` to a deleted file.

### §5.2 Layout (excluded from the default run, needs Chrome)

- New `spec/layout/translation_review_layout_spec.rb`, the fifth file on
  `spec/support/layout_measurement.rb`. Both themes, 390×680 and 1280×800: no horizontal overflow;
  a flagged row's (or card's) computed left border colour equals `--danger` and an unflagged one's
  does not; at 390 every proposal row is a card (`display: block`); the textarea's width equals its
  cell's content width.
- `spec/layout/styleguide_layout_spec.rb`: the styleguide gains a `datetime-local` specimen holding a
  real value, so the date input is measured for border contrast and type scale like every other
  control.

### §5.3 Gates and screenshots

Run by the orchestrator, **each alone, on a fresh isolated database** (concurrent runs in one
checkout collide on `tmp/storage`): full RSpec; all five layout files; full Cucumber; the inherited
contract, which must read 228 / 2325; `git diff origin/master -- features/` empty. Before/after
screenshots, both themes, 390 and 1280: the new-game form (date fields and hint), the invitation
page, translation review with one flagged and one clean proposal.

### §5.4 Rollout

One PR from `design/widgets-and-review`. Commits in reviewable order: error formats and their
spec → date fields and hint, then the calendar deletion → datalist, then the autocomplete deletion
→ translation review → CLAUDE.md (the sentence-format rule; the fifth layout spec; the leaf-key
count and the RSpec count, both measured at the commit). No migration, no new gem; net about
−3,200 lines.

## Out of scope

- Per-game timezones (§ Decisions).
- Retiring jQuery from the game page and the play screen.
- Rewriting predicate-style messages as sentences, or vice versa.
- Any `.feature` file.
- C, E, D — later wave items.
