# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Ruby web app for running urban "encounter" games, built on **Merb 1.1**, not Rails. Merb was
discontinued in 2009 after merging into Rails 3. Rails idioms do not apply — see below. The
framework itself is vendored as git submodules pointing at forks (`vendor/merb`, `vendor/merb-auth`).

## Setup

The submodules are required; the app will not boot without them.

```bash
git submodule update --init --recursive
bundle install --without production
```

Ruby is pinned to **2.6.5** (`Gemfile`, `Gemfile.lock`), bundler 2.2.3. `config/database.yml` is
gitignored — copy `config/database.yml.sample` if it is absent. Development uses sqlite
(`db/development.sqlite`); production uses Postgres via `DATABASE_URL`.

## Commands

```bash
bundle exec cucumber                      # full feature suite — this is what CI runs
bundle exec cucumber features/games/create-game.feature   # single feature
bundle exec rspec spec/                   # specs
bundle exec rspec spec/models/game/created_by_spec.rb     # single spec file
bundle exec merb                          # dev server, port 4000
```

`MERB_ENV` selects the environment (`development`, `test`, `production`, `rake`) — it is the
equivalent of `RAILS_ENV`. Heroku sets both `MERB_ENV` and `RACK_ENV`.

Ruby is installed via rbenv and is not on `PATH` in non-login shells. Prefix commands with
`export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.

Run migrations with `MERB_ENV=rake bundle exec rake db:migrate`. The `rake` entry point prints
`Skipping Merb plugin rakefile merb-auth-slice-password/spectasks` on every invocation — that is
expected. Those are RSpec 1 rake tasks that cannot load under RSpec 3; `Rakefile` skips
unloadable plugin rakefiles rather than letting one abort every task, which is what used to
happen.

## Merb, not Rails

- Controllers live in `app/controllers/<plural>.rb` and subclass `Application` — there is no
  `ApplicationController`, and no `_controller` filename suffix.
- Filters are `before :method, :only => [...]` / `:exclude => [...]`, not `before_action`.
- **Actions must call `render` explicitly.** There is no implicit template rendering.
- URL helpers are `resource(@game)` / `resource(@game, :edit)`, not `game_path`.
- Routes are declared in `config/router.rb` inside `Merb::Router.prepare`.
- No strong parameters — `params[:game]` is passed straight to `update_attributes`.
- Authentication comes from the `merb-auth-*` slices, configured in `merb/merb-auth/`.
- ActiveRecord 4.2 is used standalone, without the rest of Rails.

## Testing

Two suites, both on frozen versions:

- **Cucumber 0.10.6** — features in `features/`, written in **Russian Gherkin**
  (`# language: ru`, `Функционал:`, `Сценарий:`, `Допустим`/`Если`/`То`). Steps live in
  `features/*/steps/*_steps.rb` and are loaded recursively by `features/support/env.rb`.
  `features/step_definitions/` is generated and gitignored — never add steps there.
- **RSpec 3** — migrated from RSpec 1.3. `spec/spec_helper.rb` enables the legacy `should` syntax
  for both expectations and mocks, so the existing `x.should == y` assertions still work; new
  specs may use either syntax. Each spec file requires the helper by relative path:
  `require File.join(File.dirname(__FILE__), '..', '..', 'spec_helper.rb')`.

  Merb's RSpec integration (`merb-core/test/test_ext/rspec.rb`) is built on RSpec 1 internals
  and no longer loads — Merb swallows the `LoadError` silently. Two consequences: the
  `be_successful` / `redirect_to` matchers are reimplemented in
  `spec/spec_helpers/merb_matchers.rb`, and `features/support/env.rb` re-defines the
  `Merb::Test::Matchers` / `Merb::Test::ViewHelper` modules that `merb_cucumber` expects.

The test database is in-memory sqlite. `spec_helper.rb` calls `ActiveRecordHelper.recreate_database!`,
which replays every migration in `schema/migrations/` from zero. There is no `schema.rb` — the
numbered migrations are the schema. Add a new `NNN_name_migration.rb` rather than editing an
existing one.

Object factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` (`create_user`,
`create_game`, `create_level`) — not FactoryBot.

## Conventions

- Every Ruby file starts with `# -*- encoding : utf-8 -*-`. Keep it on new files.
- Hash rockets (`:key => value`) are used throughout, including for symbol keys. Match the
  surrounding file rather than switching to `key:` syntax.
- User-facing strings and Cucumber features are in Russian. Code, identifiers, and comments
  are in English.

## Modernization posture

Prefer modern equivalents where the change is incremental and self-contained — for example
RSpec 1.x assertion syntax, Ruby version bumps, or dependency upgrades — and say what the
upgrade buys.

Migrating off Merb to Rails is a different category: it would rewrite controllers, routing,
views, and the auth slices. Do not begin that port as a side effect of another task; raise it
as its own decision.

Several dependencies are pinned with comments explaining the block (`rake` pending an RSpec
upgrade, `sqlite3 <1.4` pending a Rails upgrade). Those comments mark real ordering
constraints — read them before bumping a version.

## Deployment

Heroku. `Procfile` runs `merb -a thin`. `create-heroku-instance <app-name> <TZ>` provisions a
new instance and sets `MERB_ENV`/`RACK_ENV`/`TZ`.

**Security:** `config/init.rb` contains a hardcoded, committed `session_secret_key`. Any real
deployment must override it — flag this if touching session or auth code.
