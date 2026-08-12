# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Ruby on Rails 8 web app for running urban "encounter" games — teams register, join a game, and
race through levels by answering location-based puzzle codes. It was ported from Merb 1.1 (see
`git log` before this port's commits); the framework, vendored submodules, and Merb conventions
are gone. This is a plain, current Rails app — Rails idioms apply.

## Setup

```bash
bundle install
bin/rails db:setup db:test:prepare
```

libvips is a **system library**, not a gem — `bundle install` succeeds without it, and uploads
cannot work without it. **The package name differs by distribution**, and getting it wrong reads
as "libvips is unavailable" rather than "you typed the wrong package":

```bash
sudo apt-get install -y libvips42t64 libheif1   # Ubuntu 24.04 "noble" and later
sudo apt-get install -y libvips42   libheif1    # Debian bookworm — what the Dockerfile installs
```

Ubuntu renamed the library package in its 64-bit `time_t` transition, so on noble `libvips42` has
no candidate at all and `apt-get` answers *"Unable to locate package"*. This bit a real session:
the instruction here originally said `libvips42` for both, was reviewed twice, and was correct —
for the container. The error existed only at the seam between the image and a developer's machine.

`libheif1` is the HEIC half specifically, and it is not optional in practice: libvips can be built
without HEIC, a photo from any iPhone arrives as HEIC, and HEIC is the one in-scope upload format
that needs converting. Verify you got both:

```bash
ruby -e 'require "vips"; puts Vips.get_suffixes.include?(".heic")'   # must print true
```

Without libvips at all, `spec/image_processing_spec.rb` fails on purpose: it **raises** rather than
skips, so a missing libvips shows up as a red build instead of a quietly-pending example — see that
spec and the `shared.countdown.*` note under Testing for the same pattern. Without *HEIC* support
specifically, one conversion example in `spec/models/game_file_upload_spec.rb` skips locally and
**raises in CI**, since the shipped image is built with libheif and the `app-image` job proves it.

Ruby is pinned to **3.3.12** (`.ruby-version`, `Gemfile`), installed via rbenv, and is **not on
`PATH` in non-login shells**. Prefix commands with:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
```

`config/database.yml` is committed and points development/test at sqlite (`db/development.sqlite3`,
`db/test.sqlite3`); production uses Postgres via `DATABASE_URL`. Neither sqlite file is in the
repository — `db:setup`/`db:test:prepare` create them from `db/schema.rb`.

## Commands

```bash
bundle exec cucumber                                       # full feature suite — the acceptance gate
bundle exec cucumber features/games/create-game.feature     # single feature
bundle exec rspec                                           # all specs (no path argument needed)
bundle exec rspec spec/models/game_passing/check_answer_spec.rb   # single spec file
bin/rails server                                             # dev server, port 3000
bin/rails db:migrate                                         # migrations (db/migrate/*, standard Rails)
bin/rails zeitwerk:check                                     # autoloading sanity check
```

`RAILS_ENV` is the standard Rails environment switch (`development`, `test`, `production`).

## The acceptance-suite rule

`features/**/*.feature` files are the contract this port was validated against — byte-identical to
what the original Merb app passed, scenario for scenario. **Never edit a `.feature` file**, not
even whitespace, regardless of how compelling the reason seems. If a feature looks wrong, that is
a signal to look harder at the implementation, or to raise it as a separate, explicit decision —
not to "fix" the spec. Step definitions (`features/*/steps/*_steps.rb`, `features/support/env.rb`)
are fair game.

**Which files the freeze covers.** All 59, but for two different reasons, and the distinction
decides whether an edit needs the owner's authorisation:

  * **The 58 inherited Russian files** are the Merb contract. "Byte-identical to what the original
    app passed" is a claim anyone can check mechanically with `git diff` against the pre-port
    revision, and that check is the whole value — it is what separates "the port preserved
    behaviour" from "the app and its spec drifted toward each other." Editing one takes an explicit,
    recorded decision by the repository owner. The three below are the only ones so far.
  * **One file this port wrote itself** — `features/i18n/switch-language.feature`, English, added
    2026-08-04 in `6d554a8` for the locale switcher, which is platform behaviour the Merb app never
    had. It has no pre-port ancestor, so there is nothing for it to be identical *to* and no owner
    authorisation to obtain; it changes under ordinary review, like any other test this repository
    owns. It has been edited once, in `d802659`, where review found the scenario was guarding a bug
    that did not exist and repurposed it onto a real one. That is not a fourth amendment and is not
    counted as one. A new `.feature` file written by this repository joins this set; adding one is
    not an amendment either.

What does **not** vary by provenance: no `.feature` file of either set is edited to make a failing
test pass. On an inherited file that is a contract breach; on a port-authored one it is the same
mistake wearing different clothes — deleting a requirement and booking it as a fix.

**Three authorised exceptions exist so far.** On 2026-08-06 the repository owner explicitly authorised
amending `features/games/user-profile-view-and-edit.feature` to drop the ICQ and Jabber fields,
which were retired from the product along with their database columns (see
`docs/superpowers/specs/2026-08-06-profiles-and-games-list-design.md` §2.3). Four scenarios lost
their ICQ/Jabber steps and table rows; the two step definitions that carried those arguments were
narrowed to match. The scenario count did not change — 234 before and after — and the step total
fell by 4, which is exactly the four `ввожу ... в поле` lines removed.

On 2026-08-07 the repository owner explicitly authorised a second amendment, to the same file:
the "Изменение пароля пользователя" scenario in `user-profile-view-and-edit.feature` gained one
step, `Если ввожу "testpass" в поле "Текущий пароль"`, immediately before the existing
new-password steps. This is because the profile form now requires the current password before
accepting a new one (CWE-620, task 2 of the 2026-08-07 security-account-protection plan): the
form previously let anyone with a logged-in browser set a new password with no verification of
the old one, and this app has no password-reset flow — a later task in that same plan (task 5)
adds one — so an unverified change was a permanent, unrecoverable takeover for the legitimate
owner. The scenario count did not change — 234 before and after — and the step total rose by 1,
from 2358 to 2359, which is exactly the one step added.

On 2026-08-08 the repository owner explicitly authorised a third amendment, a product redesign of
signup rather than a fix from a security review: registration no longer collects a password at
all (nickname and email only) — the server generates the first one, the welcome letter keeps
carrying it and gains a line urging the user to change it promptly, and a successful login is
treated as the email verification (no verification column, no gating — implicit by design). Three
changes follow, all in the signup surface:
  * `features/signup/signup.feature`, "Удачная регистрация" — the two `ввожу ... в поле "Пароль"`/
    `"Подтверждение"` steps are gone (there is nothing left to fill), and the final assertion
    changed from `И одно письмо с текстом "1234" должно быть выслано на aldor@diesel.kg` to
    `И одно письмо должно быть выслано на aldor@diesel.kg` — the scenario can no longer know the
    generated value, only that a letter went out. The new step shape had no existing definition;
    one was added to `features/steps/mail_steps.rb`.
  * `features/signup/signup.feature`, "Подтверждение пароля не совпадает" — deleted outright. With
    no confirmation field at signup there is nothing left for it to assert.
  * `features/games/signup-password.feature` — deleted outright. Its one scenario asserted that
    the signup form's `Пароль`/`Подтверждение` fields were `type="password"`; both fields are gone.
  * "Повторная регистрации с тем же именем и адресом" (yes, that's the scenario's real title, typo
    and all — not something this task touched) is unchanged: nickname is still a signup field and
    its duplicate-name assertion still holds.
  The scenario count went from 234 to 232 (the two deleted scenarios); the step total went from
  2359 to 2342 (-2 for the removed password/confirmation fills, -11 for the deleted
  "Подтверждение пароля не совпадает" scenario, -4 for the deleted signup-password.feature file).

**If you re-count the scenarios yourself**, expect 3 fewer than the figures above. Those are
Cucumber's numbers; a `grep -c` of `Сценарий:`/`Scenario:` headers gives 231/229, because
`features/time/time-in-header.feature` holds the suite's only `Структура сценария` and Cucumber
counts its 4 `Примеры` rows as 4 scenarios where the grep counts the outline once. An amendment is
audited on the *delta*, and the deltas agree either way: 0, 0, -2.

This is recorded so the amendments are traceable, **not** to soften the rule. The rule stands exactly
as written above: a feature file is changed only on an explicit, recorded decision by the
repository owner, never as a convenience and never to make a failing test pass.

Cucumber features are written in **Russian Gherkin** (`# language: ru`). Step defs live beside
their features and are loaded by `features/support/env.rb` via `-r features/support` (see
`config/cucumber.yml`) — `features/step_definitions/` is deliberately gitignored and unused; don't
add steps there or Cucumber will auto-require them a second time.

## i18n design

- **Platform chrome is translated; author-written game content never is.** Menus, buttons,
  validation messages, flash notices, and mailer boilerplate go through `t()`/`l()`. Game titles,
  level descriptions, hints, and question text are free-text authored by game creators and are
  rendered verbatim — running them through `t()` would print `translation missing:` into a live
  game the moment a key doesn't exist. See `features/i18n/switch-language.feature` and the comment
  in `app/views/layouts/_header.html.erb`.
- **`ru` is the default locale**, and **seven** locales are registered
  (`config.i18n.available_locales` in `config/application.rb`), all seven complete at **590 leaf
  keys** each: `ru`, `en`, `uk`, `ka`, and `tr`, `be`, `pl` added on 2026-08-09.
  `config.i18n.fallbacks` sends anything missing to `:ru`, which is what makes it safe to add a key
  to `ru.yml` before the others catch up — `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity but
  only requires the other five to be a subset, so they can lag without a red build. Translations
  live in `config/locales/{en,ru,uk,ka,tr,be,pl}.yml`. **Count the keys rather than trusting this
  number**; it was documented as 489 for some time after it was 587.
- **Subset-of-`ru` is not completeness, and the gap is invisible.** A locale file carrying nothing
  but its seven endonyms satisfies every check in `spec/i18n_spec.rb`, and fallbacks then render
  the *Russian* play screen mid-game to a player who chose another language — nothing raises,
  nothing is blank. `spec/i18n_play_screen_spec.rb` pins the eleven strings a team reads under time
  pressure across every locale on its `SHIPPED_LOCALES` list, reading the YAML files directly
  (going through `I18n` would resolve the fallback and assert nothing). A language joins that list
  in the same PR that translates it, and a second example fails if a registered locale is missing
  from the list altogether.
- **`locales.*` is the one block that cannot fall back, and registering a locale without it breaks
  every page with a header.** `locales.tr` missing from `tr.yml` falls back to `ru.yml` — where it
  is also missing, because it is a new *key*, not a new translation — and the test environment's
  `raise_on_missing_translations` turns that into a raise. Five views render `t("locales.#{l}")`
  for every available locale (`layouts/_header`, `users/edit`, `games/new`, `games/edit`,
  `shared/_language_tabs`), so adding `:xx` to `available_locales` without adding `locales.xx` to
  **all seven files** took 224 examples red in one go. `spec/i18n_spec.rb` guards this now.
- **`rails-i18n` is in the Gemfile, and the app's own files win over it.** It supplies what this
  repo would otherwise hand-author per language: `date:`/`time:` formats, ActiveRecord validation
  defaults, and CLDR plural rules. The gem's files enter `I18n.load_path` *before*
  `config/locales/*.yml`, so anything this repository defines takes precedence — only four key
  paths exist in both, and `spec/i18n_rails_defaults_spec.rb` pins the two whose values actually
  differ (`time.formats.short`, `activerecord.errors.messages.record_invalid`). Those two are the
  only places an inverted load order would ever be visible; a validation message the gem does not
  define cannot demonstrate anything about precedence.
- **No key in this app uses I18n pluralisation, and that was load-bearing before the gem.** The
  three `t()` calls passing `count:` are plain `%{count}` interpolation (`"Коды (%{count}):"`), and
  no `one:`/`few:`/`many:`/`other:` key exists anywhere. (The countdown *is* pluralised, but by
  hand and outside I18n entirely — see the `shared.countdown.*` note below.) Rails' built-in
  pluralizer knows `one`/`other` only, so the first genuinely pluralised key would have raised
  `I18n::InvalidPluralizationData` — in `ru`, the default locale, before any new language was
  involved. `rails-i18n` supplies the CLDR rules, so pluralised keys are now safe to write.
- **Five of the seven locales are machine-produced and unreviewed: `uk`, `ka`, `be`, `pl`, `tr`.**
  Only `ru` and `en` have been read by a speaker. All five are complete and structurally verified —
  every interpolation variable matches and all 590 keys resolve at runtime — but the *wording* has
  not been checked by anyone. This is a known, recorded state rather than an oversight, and the
  bottleneck on fixing it is native review, not engineering. Each file says so in its own header
  comment too. **Turkish is the one to get reviewed first** if only one can be: it needed
  structural rewording rather than word-for-word translation (see below), so it has the most room
  to read oddly. Treat reported wording problems in any of the five as real.
- **Turkish reworded every interpolated name rather than translating around it.** Turkish is
  agglutinative: a case suffix cannot attach to `%{team}`/`%{nickname}`/`%{game}`, because which
  suffix is correct depends on the name's final vowel and whether it ends in a consonant — and the
  value is a name a player typed. All 37 keys carrying a user-authored value put the suffix on a
  common noun instead, mostly via `«%{team}» adlı takım` ("the team named X"). If you add a key
  with a user-authored placeholder, do the same, and check it by rendering with a consonant-final
  and a vowel-final name — if only one reads naturally, the template is inflecting around the
  placeholder. The `i`/`İ` casing hazard needs nothing extra: both layouts set
  `<html lang="<%= I18n.locale %>">`, so the five `text-transform: uppercase` rules get Turkish
  casing from the browser. **Never add a Ruby-side `.upcase`/`.downcase` to user-facing text** —
  it is locale-blind and turns `i` into `I` rather than `İ`.
- **`shared.countdown.*` is a hand-rolled plural array, not an i18n pluralisation.** The countdown
  ticks client-side, so the rule has to be JavaScript — `n` changes after the page is sent.
  `app/views/shared/_countdown.html.erb` emits a three-element array per unit and a function
  picking one of the three indices. That function was **one hard-coded East Slavic rule for every
  locale** until 2026-08-09, which is right for `ru`/`uk`/`be` and wrong elsewhere in a way that
  only shows at particular numbers: its "one" slot fires for 1, 21, 31, 101…, so Polish read
  `21 rok` instead of `21 lat`, and English read `21 year`. It is now
  `ApplicationHelper#countdown_plural_function`, three rule families
  (`east_slavic`, `polish`, `one_other`) selected by locale, with `one_other` the default — safe
  both for simple pluralisation and for `tr`/`ka`, whose three slots hold the same word anyway.
  **If you add a locale, check whether it needs a family**; the default is correct unless it has
  Slavic-style few/many forms.
  `spec/helpers/countdown_plural_spec.rb` and the locale examples in `spec/views/countdown_spec.rb`
  run the emitted JavaScript **through `node`** rather than reimplementing the rule in Ruby — a
  Ruby mirror would agree with itself while the shipped JavaScript stayed broken. Both were
  mutation-tested against the old inline rule and fail with `21 dzień` / `21 day`.
- **The RSpec CI job installs `node`, and that step is load-bearing.** The job runs inside
  `container: ruby:3.3.12` — a Debian image with no `node`, and the runner's own `node` is not
  visible from inside a container. `spec/views/countdown_spec.rb` used to guard its Node examples
  with `skip(...)`, so from the day they were written until 2026-08-09 they reported **pending in
  every CI run**, which reads exactly like passing unless you count. They were only ever really
  running on a developer's laptop. Both files now **raise** instead of skipping: if the binary
  disappears the suite goes red rather than quietly shedding coverage. Don't turn that back into a
  `skip`, and don't drop the `actions/setup-node` step.
- **Georgian needed the same treatment as Turkish, and got it first.** It was restructured rather
  than translated word-for-word wherever the template's fixed word order fights the language: the
  hint delay labels, which bracket a number Georgian postposes; and anywhere a user-supplied name
  is interpolated, where the case suffix was moved onto a preceding common noun so it never lands
  on the name.
- A signed-in user's stored locale preference beats the instance default; an explicit `?locale=`
  query param beats both (`app/controllers/concerns/locale_selection.rb`).
- `DEFAULT_LOCALE` (env var, defaults to `ru`) sets the instance-wide default in production —
  see `create-heroku-instance`.

## Known, deliberate design: the CSS-hidden locale dropdown

`app/views/layouts/_header.html.erb` renders the language switcher as a dropdown whose menu is
hidden by a rule in `public/stylesheets/layout.css` (`.locale-menu { display: none }`, revealed on
`:hover`/`:focus-within`). Hiding interactive links in an external stylesheet looks like something
to tidy up. **It is the only construction that works here**, and the reason is worth knowing before
touching it.

`features/i18n/switch-language.feature:37` is frozen, and its step definition does
`within("#locale-switcher") { click_link(label) }`. **Capybara's rack-test driver parses neither
stylesheets nor computed style** — `Capybara::Node::Simple#visible?` (capybara 3.40.0) checks
exactly five things: `input[type=hidden]`, `<template>`, the `hidden` **attribute**, an **inline**
`style` containing `display: none`, and `script`/`head`/`style` tags. So a link hidden by an
external CSS rule is fully clickable for the acceptance suite while being genuinely invisible to a
person. Verified: `bundle exec cucumber features/i18n` passes with the menu closed.

Therefore:

- Do **not** move the hiding into an inline `style` or a `hidden` attribute — either one is in that
  list of five and would make `click_link` fail.
- Do **not** rebuild it as `<details>`/`<summary>`. That element *is* special-cased: the matcher's
  `VISIBILITY_XPATH` contains `(~x.self(:summary) & XPath.parent(:details)[!XPath.attr(:open)])`,
  so non-summary children of a closed `<details>` are invisible. (The rule tests the *direct*
  parent, so deeper nesting happens to slip through — do not rely on that.)
- Do **not** make it a `<select>`. It would need JavaScript to navigate on change, and this app has
  no Turbo and no rails-ujs — see the `GET /logout` wart below.
- Keep real `<a>` elements inside an element with `id="locale-switcher"`.

Why a dropdown at all: one link per locale wrapped the phone header onto three rows. Measured on
the home page at 390×660 with seven locales registered, header height went **225px → 125px** and
the switcher **88px → 44px**; at 375×553 the same 225px was 41% of the visible screen. Desktop
(1280×800) is unchanged at 69px. Horizontal overflow is 0 at every size, and the open menu is
absolutely positioned, so it overlays the page instead of growing the header (verified: header
stays 125px with the menu forced open). Layout is not visible to either suite — re-measure with the
headless-browser procedure recorded in the `.playbar` comment in `public/stylesheets/screens.css`
before changing any of this.

## Known, deliberate wart: `GET /logout`

`config/routes.rb` defines both `get "/logout"` and `delete "/logout"`, and
`app/views/layouts/_left_menu.html.erb` links to it with a plain `<a>`, not a `button_to`/DELETE
form. This looks wrong for a Rails app and it is tempting to "fix" by removing the GET route and
converting the link to a DELETE button. **Don't** — `features/authentication/logout.feature:9`
drives logout with a raw `GET /logout` (Capybara `#visit`), and feature files are read-only (see
above). The GET route has to stay for that scenario to keep passing. Both routes are kept
deliberately; this is documented in `config/routes.rb` too.

## Testing

- **Cucumber** — `features/**/*.feature`, Russian Gherkin. 232 scenarios (230 passed, 2 undefined),
  2342 steps (the 2 undefined scenarios are pre-existing empty placeholders — not a regression).
  Profiles live in `config/cucumber.yml` (default / `rerun` / `wip` / `all`).
- **RSpec** — 1222 examples, 0 failures, 6 pending (unimplemented controller specs, pre-existing).
  **Do not trust a quoted RSpec count** — this number has moved five times in a week and stale copies
  have been cited as current twice. Re-run it. Cucumber's 232/2342 is the stable figure.
  `spec/rails_helper.rb` enables the legacy `should` syntax
  (`config.expect_with :rspec do |c| c.syntax = [:should, :expect] end`) because roughly 140
  assertions ported from the Merb-era RSpec 1.x suite still use `x.should == y`; new specs may use
  either syntax, prefer `expect`.
- The test database is real sqlite (`db/test.sqlite3`), managed the standard Rails way —
  `db/schema.rb` plus `ActiveRecord::Migration.maintain_test_schema!` in `rails_helper.rb`. Run
  `bin/rails db:test:prepare` after adding a migration, same as any Rails app.
- Object factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` (`create_user`,
  `create_game`, `create_level`, ...) — not FactoryBot. Keep using them; don't introduce FactoryBot
  for new specs without raising it first. **`create_user` takes no arguments** — it generates its own
  nickname and e-mail; passing a hash raises `ArgumentError`.
- **`Rails.cache` is real now, and process-global.** `config.cache_store = :memory_store` in both
  production and test (it was Rails' `:file_store` default, which in test persisted `tmp/cache`
  *between* runs). It does not roll back with the transaction around an example, so
  `spec/rails_helper.rb` and `features/support/env.rb` both clear it before each example/scenario.
  The Cucumber hook is load-bearing, not tidiness: `Given зарегистрирован пользователь X` drives the
  real signup form, so nearly every scenario POSTs through the rate-limited controller from
  `127.0.0.1` — with the hook removed, 5 of 11 scenarios fail in `features/signup` and
  `features/teams` alone.
- **Neither suite covers `config/environments/production.rb`.** Both run in the test environment, so
  that file is never evaluated — a change to it can be green locally and still break the image. The
  `app-image` CI job ("Prove the image actually serves") is what catches it. To check locally, boot
  the environment directly:
  `RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'`
  (sqlite because `pg` is production-group and not in the local bundle).
- **ActiveSupport core extensions are NOT all loaded in an environment file.** `config/application.rb`
  requires railties selectively rather than `rails/all`, so `active_support/all` is never pulled in,
  and an environment file is evaluated during `initialize!` before the component that would have
  loaded a given core extension. `32.megabytes` raises `NoMethodError` on `Integer` there while
  working fine anywhere that runs after boot. Write the literal, or require the specific core_ext.
- **A new validator needs its message in all four locales.** This app carries no `rails-i18n`, and
  the test environment sets `raise_on_missing_translations`, so a validator with no
  `activerecord.errors` entry fires correctly and then raises `I18n::MissingTranslationData` while
  rendering its message — which reads like a broken test rather than a missing key.

## Conventions

- Many older files start with `# -*- encoding : utf-8 -*-` (or, inconsistently,
  `# coding: utf-8` — see `app/models/level.rb`). It's not universal: files this port itself wrote
  (`config/application.rb`, `config/routes.rb`, `app/controllers/concerns/locale_selection.rb`,
  and others) have neither. Ruby's been UTF-8-by-default since Ruby 2.0, so the comment is a no-op
  either way — match the surrounding file, don't feel obligated to add it to new ones.
- Hash rockets (`:key => value`) are used throughout, including for symbol keys. Match the
  surrounding file rather than switching to `key:` syntax.
- User-facing strings and Cucumber features are in Russian (or `t()` calls resolving to Russian).
  Code, identifiers, and comments are in English.

## A carried-forward data-safety fix worth knowing about

`app/models/game_passing.rb`'s `AnsweredQuestionsCoder` reads/writes the `answered_questions`
column. Older rows (written before this coder existed, storing full YAML-dumped ActiveRecord
objects) can raise `Psych::DisallowedClass` under Rails' safe YAML loading. `.load` rescues that
and returns `[]` rather than 500ing — see the class comment and
`spec/models/game_passing/answered_questions_spec.rb` ("legacy pre-coder format" spec) for the
reasoning and proof.

## Deployment

Kamal 2, to a single Ubuntu VM on Azure — one instance serves every community, not one Heroku app
per instance as before. `config/deploy.yml` is the deploy config (service, proxy/TLS host, GHCR
registry, the `db` accessory running Postgres with wal-g/Azure Blob backups); `.kamal/secrets`
composes the secret env vars (`SECRET_KEY_BASE`, `DATABASE_URL`, SMTP credentials) from the
environment, never a literal. `.github/workflows/deploy.yml` (`workflow_dispatch`, `deploy` or
`setup`) runs `bundle exec kamal <command>` from CI, authenticating to Azure via OIDC to punch a
just-in-time hole in the NSG for the runner's IP and closing it again afterward. See
`docs/superpowers/specs/2026-08-05-kamal-deployment-design.md` for the design and
`docs/runbooks/restore.md` for restoring the production database.

`create-heroku-instance <app-name> <TZ> [DEFAULT_LOCALE]` is the old per-instance Heroku
provisioning script (sets `RAILS_ENV=production`, `TZ`, `DEFAULT_LOCALE`, generates a
`SECRET_KEY_BASE`). It is no longer how production is deployed — kept for now as history, not as a
live tool.

**Session secret:** this app has no `config/credentials.yml.enc`/`master.key` and no
`config/initializers/`, so `secret_key_base` (which the cookie session store, and everything else
that signs or encrypts, derives from) comes from the `SECRET_KEY_BASE` environment variable —
Rails' own default lookup, nothing app-specific reads or maps it. **In `development`/`test` Rails
auto-generates one per checkout** (`tmp/local_secret.txt`, gitignored, created on first boot) so a
fresh clone runs with no setup. **In `production` there is no fallback**: boot raises
`ArgumentError: Missing 'secret_key_base' for 'production' environment` if `SECRET_KEY_BASE` is
unset — verified by booting with `RAILS_ENV=production` both with and without it set. Never
introduce a committed default or fallback for production — this repository is public. In the Kamal
deploy, `SECRET_KEY_BASE` is a GitHub Actions secret, read into `.kamal/secrets`, and never
committed.

Historical note: the Merb app read a variable named `SESSION_SECRET_KEY` from
`config/init.rb`, which Task 1 deleted when the Rails skeleton replaced it. Both the Heroku script
and the current Kamal secrets set `SECRET_KEY_BASE`, the name Rails 8 actually reads; nothing in
this codebase reads `SESSION_SECRET_KEY` any more, so don't reintroduce that name expecting it to
do anything.

**Developer-machine credentials: never a literal in a config file.** The same rule as
`SECRET_KEY_BASE` above, extended to the tokens a working session touches. On 2026-08-06 a GitHub
PAT and a GitLab PAT were found sitting as plaintext strings in `~/.claude/settings.json`, read
aloud into a transcript by an ordinary `cat` of that file, and had to be revoked. Both were
`repo`-scoped classic tokens, and neither was load-bearing: `gh` keeps its own OAuth token in
`~/.config/gh/hosts.yml`, `origin` is SSH, and every PR that day was created through `gh`. Full
credentials, zero benefit.

So:

- **Prefer SSH and the `gh`/`glab` CLIs.** They hold their own credentials outside any file that
  gets pasted, quoted or summarised. Nothing in this repository's normal workflow needs a PAT.
- **If a token is genuinely required**, put the value in the environment (a `chmod 600` file your
  shell sources) and let the config reference only the variable *name*. Never the value.
- **Prefer fine-grained, single-repository, expiring tokens** over classic `repo` scope, so a leak
  is bounded in blast radius and in time.
- **When reading a config file, read the line you need** — `grep`, not `cat`. A whole-file dump of
  something under `~/.claude/`, `~/.config/` or `~/.ssh/` is how a secret reaches a transcript.
- A revoked credential left in place is not harmless: it is an invitation to "fix" the broken
  integration later by pasting a fresh one into the same slot. Remove the block, don't blank it.
