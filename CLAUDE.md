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
- **`ru` is the default locale.** `en`, `uk`, and `ka` are registered (`config.i18n.available_locales`
  in `config/application.rb`) so the language switcher lists them, but `uk` and `ka` are largely
  untranslated beyond the language-name keys the switcher itself needs — `config.i18n.fallbacks`
  sends everything else to `:ru`. Don't treat missing `uk`/`ka` copy as a bug; it's the known state
  until someone does the translation work. Translations live in `config/locales/{en,ru,uk,ka}.yml`.
- A signed-in user's stored locale preference beats the instance default; an explicit `?locale=`
  query param beats both (`app/controllers/concerns/locale_selection.rb`).
- `DEFAULT_LOCALE` (env var, defaults to `ru`) sets the instance-wide default in production —
  see `create-heroku-instance`.

## Known, deliberate wart: `GET /logout`

`config/routes.rb` defines both `get "/logout"` and `delete "/logout"`, and
`app/views/layouts/_left_menu.html.erb` links to it with a plain `<a>`, not a `button_to`/DELETE
form. This looks wrong for a Rails app and it is tempting to "fix" by removing the GET route and
converting the link to a DELETE button. **Don't** — `features/authentication/logout.feature:9`
drives logout with a raw `GET /logout` (Capybara `#visit`), and feature files are read-only (see
above). The GET route has to stay for that scenario to keep passing. Both routes are kept
deliberately; this is documented in `config/routes.rb` too.

## Testing

- **Cucumber** — `features/**/*.feature`, Russian Gherkin. 234 scenarios, 2362 steps (2 scenarios
  are pre-existing empty placeholders reported as "undefined" — not a regression). Profiles live in
  `config/cucumber.yml` (default / `rerun` / `wip` / `all`).
- **RSpec** — 407 examples, 0 failures, 6 pending (unimplemented controller specs, pre-existing).
  `spec/rails_helper.rb` enables the legacy `should` syntax
  (`config.expect_with :rspec do |c| c.syntax = [:should, :expect] end`) because roughly 140
  assertions ported from the Merb-era RSpec 1.x suite still use `x.should == y`; new specs may use
  either syntax, prefer `expect`.
- The test database is real sqlite (`db/test.sqlite3`), managed the standard Rails way —
  `db/schema.rb` plus `ActiveRecord::Migration.maintain_test_schema!` in `rails_helper.rb`. Run
  `bin/rails db:test:prepare` after adding a migration, same as any Rails app.
- Object factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` (`create_user`,
  `create_game`, `create_level`, ...) — not FactoryBot. Keep using them; don't introduce FactoryBot
  for new specs without raising it first.

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

Heroku. `Procfile` runs `puma`. `create-heroku-instance <app-name> <TZ> [DEFAULT_LOCALE]`
provisions a new instance, sets `RAILS_ENV=production`, `TZ`, `DEFAULT_LOCALE` (defaults to `ru`),
and generates a per-instance `SECRET_KEY_BASE`.

**Session secret:** this app has no `config/credentials.yml.enc`/`master.key` and no
`config/initializers/`, so `secret_key_base` (which the cookie session store, and everything else
that signs or encrypts, derives from) comes from the `SECRET_KEY_BASE` environment variable —
Rails' own default lookup, nothing app-specific reads or maps it. **In `development`/`test` Rails
auto-generates one per checkout** (`tmp/local_secret.txt`, gitignored, created on first boot) so a
fresh clone runs with no setup. **In `production` there is no fallback**: boot raises
`ArgumentError: Missing 'secret_key_base' for 'production' environment` if `SECRET_KEY_BASE` is
unset — verified by booting with `RAILS_ENV=production` both with and without it set. Never
introduce a committed default or fallback for production — this repository is public.

Historical note: the Merb app read a variable named `SESSION_SECRET_KEY` from
`config/init.rb`, which Task 1 deleted when the Rails skeleton replaced it. `create-heroku-instance`
now sets `SECRET_KEY_BASE`, the name Rails 8 actually reads; nothing in this codebase reads
`SESSION_SECRET_KEY` any more, so don't reintroduce that name expecting it to do anything.
