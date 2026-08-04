---
name: setup-dev
description: Bootstrap a local development environment for this Rails 8 app from a fresh clone — gems and the development/test databases.
disable-model-invocation: true
---

Bring this repository from a fresh clone to a running local server. Work through the steps in
order and stop at the first failure — later steps depend on earlier ones.

## 1. Ruby via rbenv

Ruby 3.3.12 is pinned (`.ruby-version`, `Gemfile`). If it isn't already installed:

```bash
rbenv install 3.3.12   # skip if already installed: rbenv versions
```

rbenv is not on `PATH` in non-login shells here. Prefix commands with:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
```

## 2. Gems

```bash
bundle config set --local without production
bundle install
```

The `production` group holds `pg`, which needs `libpq` headers to build and is not required
locally (sqlite is used for development/test — see `config/database.yml`). Skipping the
`bundle config` line is not just unnecessary but will actively fail the install on any machine
without `libpq-dev`/`postgresql-devel` installed — this is what CI does too
(`.github/workflows/ci.yml`).

## 3. Database

```bash
bin/rails db:setup db:test:prepare
```

`config/database.yml` is committed and already points development at `db/development.sqlite3` and
test at `db/test.sqlite3`, so no configuration is needed. Neither sqlite file is in the repository
— `db:setup`/`db:test:prepare` create them from `db/schema.rb` and `db/migrate/*`.

## 4. Verify

```bash
bundle exec rspec               # 407 examples, 0 failures, 6 pending
bundle exec cucumber            # 234 scenarios (2 undefined placeholders), 2362 steps
bin/rails server                # dev server on http://localhost:3000
```

Report which of these passed and which did not. Do not claim the environment works until the
server has actually booted and at least one suite has run.

There are no git submodules and no vendored framework — this is a plain Rails app. If a step
mentions submodules, a vendored `merb`/`merb-auth`, or Ruby 2.6, that instruction is stale; ignore
it and follow this file instead.
