---
name: run-tests
description: Run this project's RSpec specs and Russian-language Cucumber features, including single-file runs and the rerun profile. Use when verifying changes or investigating a test failure.
---

## Prerequisites

Ruby 2.6.5 is installed via rbenv and is not on `PATH` in non-login shells. Prefix with:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
```

## Cucumber (what CI runs)

`.travis.yml` runs exactly `bundle exec cucumber`, so this is the authoritative suite.

```bash
bundle exec cucumber                                    # everything (~1m45s)
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
`features/support/env.rb`. `features/step_definitions/` is generated and gitignored — never put
steps there.

## RSpec

```bash
bundle exec rspec spec/                                 # all specs
bundle exec rspec spec/models/                          # a directory
bundle exec rspec spec/models/game/created_by_spec.rb   # one file
bundle exec rspec spec/models/game/created_by_spec.rb:12    # one example by line
```

Options live in `.rspec`. The suite was migrated from RSpec 1.3 and `spec_helper.rb` enables the
legacy `should` syntax for expectations and mocks, so `x.should == y` and `x.should be_truthy`
still work alongside `expect(x).to eq(y)`.

Note when editing older specs: RSpec 3 renamed `be_true`/`be_false` to `be_truthy`/`be_falsey`,
removed `stub!` (use `stub` or `allow(...).to receive(...)`), removed `have(n).items`, and resets
mocks automatically, so there is no `rspec_reset`.

## Expected baseline

- **Cucumber: fully green** — 230 of 230 scenarios, 2355 steps. Any failure here is a real
  regression.
- **RSpec: 59 failures** of 206 examples, all pre-existing. Dominated by ~48 specs referencing
  `Question#answer`, a column removed by `schema/migrations/024_answers_migration.rb` — those
  specs were never updated after the Answer model was extracted. Another ~17 come from
  `Webrat::MerbAdapter#request` being missing, and 2 from `ActiveModel::Errors#on`, removed in
  Rails 3.1. A count above 59 is a real regression.

**Watch for date rot in features.** Scenarios that set a game start through the UI hit
`Game#game_starts_in_the_future`, which rejects past dates. Most scenarios avoid this by stubbing
`Time.now` to an earlier date in their Background first (`сейчас "2009-01-01 00:00"`), then using
2009/2010 start dates. Scenarios *without* that Background stub must use a genuinely future date
— the convention is `2099`. Two scenarios failed daily from 2021 to 2026 for exactly this reason.

## Database behaviour

`spec_helper.rb` calls `ActiveRecordHelper.recreate_database!` at load, which runs
`Migrator.down(schema/migrations, 0)` then `Migrator.migrate(...)` against **in-memory sqlite**:

- There is no `schema.rb`. The numbered files in `schema/migrations/` are the schema.
- A migration that is not reversible breaks `Migrator.down` and takes the whole suite with it.
- Editing an existing migration silently changes the test schema for every spec.

Test objects come from plain helpers in `spec/spec_helpers/fixtures_helper.rb` — `create_user`,
`create_game`, `create_level`, `create_team`, `create_question`, `create_game_passing`,
`create_hint`, plus `build_game` / `build_level`. There is no FactoryBot.

## Reporting

Quote the actual pass/fail counts and compare them against the baseline above. If a suite could
not run at all — missing gems, missing submodules, no Ruby on `PATH` — say that rather than
reporting it as a failure.
