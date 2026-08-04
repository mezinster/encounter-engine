---
name: run-tests
description: Run this project's RSpec specs and Russian-language Cucumber features, including single-file runs and the rerun profile. Use when verifying changes or investigating a test failure.
---

## Prerequisites

Ruby 3.3.12 is installed via rbenv and is not on `PATH` in non-login shells. Prefix with:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
```

## Cucumber (the acceptance gate)

`.github/workflows/ci.yml` runs `bundle exec cucumber --format progress`, so this is the
authoritative suite. `features/**/*.feature` files are read-only — see `CLAUDE.md` — they are the
contract this app was ported against, byte-identical to what the original Merb app passed.

```bash
bundle exec cucumber                                    # everything (~2 min)
bundle exec cucumber features/games/create-game.feature # one feature
bundle exec cucumber features/games/create-game.feature:23   # one scenario by line
bundle exec cucumber features/games/                    # one directory
```

Features are written in **Russian Gherkin** (`# language: ru`). Prefer targeting scenarios by
line number rather than by name. Profiles live in `config/cucumber.yml`:

- default — `--format pretty`
- `-p rerun` — replays only what failed last run, reading `rerun.txt`; adds `--strict --tags ~@wip`
- `-p wip` — only `@wip`-tagged scenarios

`rerun.txt` is gitignored and rewritten each run. `--strict` makes undefined or pending steps a
failure, so a scenario that "passes" under the default profile can still fail under `rerun`.

Step definitions are in `features/*/steps/*_steps.rb`, loaded recursively by
`features/support/env.rb`. `features/step_definitions/` is deliberately gitignored and unused —
never put steps there.

## RSpec

```bash
bundle exec rspec                                       # all specs (no path argument needed)
bundle exec rspec spec/models/                           # a directory
bundle exec rspec spec/models/game/created_by_spec.rb    # one file
bundle exec rspec spec/models/game/created_by_spec.rb:12    # one example by line
```

Options live in `.rspec`. Roughly 185 assertions ported from the pre-Rails RSpec 1.x suite still
use the legacy `should` syntax; `spec/rails_helper.rb` enables both, so `x.should == y` and
`expect(x).to eq(y)` work side by side. Prefer `expect` in new specs.

## Expected baseline

- **Cucumber: fully green** — 234 scenarios, 2362 steps. 2 scenarios report as "undefined": they
  are pre-existing empty placeholders in
  `features/multi-questional-levels/managing-additional-codes.feature` (lines 30, 32), not a
  regression. Any other failure here is real.
- **RSpec: 405 examples, 0 failures, 6 pending.** The 6 pending are unimplemented controller specs
  (`GamesController#create` x2, `GamesController#update`, `InvitationsController#accept`/`#reject`,
  `LevelsController#create`) — pre-existing placeholders, not a regression. Any failure is real.

**Watch for date rot in features.** Scenarios that set a game start through the UI hit
`Game#game_starts_in_the_future`, which rejects past dates. Most scenarios avoid this by stubbing
`Time.now` to an earlier date in their Background first (`сейчас "2009-01-01 00:00"`), then using
2009/2010 start dates. Scenarios *without* that Background stub must use a genuinely future date
— the convention is `2099`.

## Locale coverage

`spec/i18n_spec.rb` checks that `config/locales/ru.yml` and `en.yml` expose the same set of keys
(it does not require `uk`/`ka` to be complete — those are registered but only partially
translated, see `CLAUDE.md`). Run it on its own when touching any locale file:

```bash
bundle exec rspec spec/i18n_spec.rb
```

## Database behaviour

`spec/rails_helper.rb` calls `ActiveRecord::Migration.maintain_test_schema!` at load, against a
real sqlite file (`db/test.sqlite3`, `config/database.yml`) built from `db/schema.rb`. Standard
Rails behaviour:

- After adding or editing a migration in `db/migrate/`, run `bin/rails db:test:prepare`
  (or `db:migrate` then `db:test:prepare`) before the specs will see the new schema.
- There is no `schema/migrations/` directory and no in-memory database — that was the Merb-era
  setup, gone since the port.

Test objects come from plain helpers in `spec/spec_helpers/fixtures_helper.rb` — `create_user`,
`create_game`, `create_level`, `create_team`, `create_question`, `create_game_passing`,
`create_hint`, plus `build_game` / `build_level`. There is no FactoryBot.

## Reporting

Quote the actual pass/fail counts and compare them against the baseline above. If a suite could
not run at all — missing gems, no Ruby on `PATH`, database not prepared — say that rather than
reporting it as a failure.
