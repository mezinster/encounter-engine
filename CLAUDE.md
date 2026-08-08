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
- **`ru` is the default locale**, and all four registered locales (`config.i18n.available_locales`
  in `config/application.rb`) are now fully translated: `ru`, `en`, `uk` and `ka` each carry the
  same 488 leaf keys. `config.i18n.fallbacks` still sends anything missing to `:ru`, which is what
  makes it safe to add a key to `ru.yml` before the others catch up — `spec/i18n_spec.rb` enforces
  exact `ru`↔`en` parity but only requires `uk`/`ka` to be a subset, so they can lag without a red
  build. Translations live in `config/locales/{en,ru,uk,ka}.yml`.
- **The Ukrainian and Georgian were machine-produced without a native reviewer.** They are
  complete and structurally verified — every interpolation variable matches and all 488 keys
  resolve at runtime — but the wording has not been checked by a speaker. Georgian needed
  restructuring rather than word-for-word translation in a few places where the template's fixed
  word order fights the language (the hint delay labels, which bracket a number Georgian
  postposes; and anywhere a user-supplied name is interpolated, where the case suffix was moved
  onto a preceding common noun so it never lands on the name). Treat reported wording problems in
  those two locales as real, not as the known-incomplete state they used to be.
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

- **Cucumber** — `features/**/*.feature`, Russian Gherkin. 232 scenarios (230 passed, 2 undefined),
  2342 steps (the 2 undefined scenarios are pre-existing empty placeholders — not a regression).
  Profiles live in `config/cucumber.yml` (default / `rerun` / `wip` / `all`).
- **RSpec** — 967 examples, 0 failures, 6 pending (unimplemented controller specs, pre-existing).
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
