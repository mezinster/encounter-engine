# Merb → Rails Migration with Internationalization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port encounter-engine from Merb 1.1 (discontinued 2009, vendored as git submodules) to current Rails on Ruby 3.x, and make the platform UI multilingual, without changing observable game behaviour.

**Architecture:** The 59 `.feature` files are the acceptance contract and do not change. They are written in Russian Gherkin and assert Russian UI strings, so the test environment pins `I18n.locale = :ru` — this keeps all 2,829 lines valid verbatim while the UI becomes translatable. Only platform chrome is localized; user-generated content (game names, level texts, hints, answer codes) stays in whatever language its author wrote. Locale is chosen per deployment via `DEFAULT_LOCALE`, mirroring the existing per-instance `TZ` convention, with an optional per-user override. The port runs bottom-up — schema, models, auth, routes, controllers, views, mailers — with the old Merb app kept green on `master` as a reference oracle throughout.

**Tech Stack:** Ruby 3.3.x, Rails 8.0.x, ActiveRecord (sqlite3 in development/test, PostgreSQL in production), RSpec 3, Cucumber + Capybara + rack_test, Rails I18n.

## Global Constraints

- Ruby 3.3.x. Rails 8.0.x. Pin exact patch versions in `Gemfile` at Task 1 and do not drift.
- The 59 files under `features/**/*.feature` are **read-only** for the entire migration. If a scenario fails, the port is wrong, not the scenario. The only permitted exception is Task 12, which adds new files.
- **Tasks 1–10 are mid-port and the full suites cannot pass.** Task 1 replaces the Gemfile, so the Merb-coupled `spec/spec_helper.rb` and the whole webrat Cucumber suite stop loading from that moment. Each of these tasks names the exact spec files that must pass, and *only those* are its gate. Do not judge Tasks 1–10 against `bundle exec cucumber` or a full `bundle exec rspec`.
- **Task 11 restores the real gate.** From Task 11 onward, `bundle exec cucumber` (230 scenarios, 2,355 steps) and the full `bundle exec rspec` must both pass, and every later task must keep them green. Cucumber is the acceptance gate; a red Cucumber run from Task 11 on blocks the commit.
- The test environment always runs with `I18n.locale = :ru` and `config.i18n.default_locale = :ru`.
- User-generated content is **never** passed through `I18n.t`. Game names, descriptions, level names and texts, hint texts, and answer codes are author-authored data.
- No string visible in the platform UI may be hardcoded after Task 9. Every one lives in `config/locales/<locale>.yml`.
- Two locales ship: `ru` (default) and `en`. `config.i18n.fallbacks = [:ru]`.
- Preserve existing URL paths exactly (`/play/:game_id`, `/stats/...`, `/logs/...`). They appear in features and in the wild.
- Answer-code comparison must remain case-insensitive across all scripts and must ignore leading/trailing whitespace.
- Timestamps are stored UTC. Never compare formatted time strings in tests; compare instants.

---

## File Structure

**Removed entirely at Task 13:** `vendor/merb/`, `vendor/merb-auth/`, `.gitmodules`, `config/init.rb`, `config/router.rb`, `config/rack.rb`, `config/environments/*.rb`, `autotest/`, `merb/`, `slices/`, `public/merb.fcgi`, `spec/spec_helpers/merb_matchers.rb`.

**New Rails skeleton (Task 1):** `config/application.rb`, `config/environments/{development,test,production}.rb`, `config/boot.rb`, `config/database.yml`, `bin/rails`, `Rakefile`.

**Ported, one file per existing file:**

| Area | From | To | Responsibility |
|---|---|---|---|
| Models (11) | `app/models/*.rb` | same paths | Domain rules; unchanged names |
| Controllers (17) | `app/controllers/<plural>.rb` | `app/controllers/<plural>_controller.rb` | One controller per resource |
| Views (53) | `app/views/**/*.erb` | `app/views/**/*.html.erb` | Presentation only |
| Mailers | `app/mailers/notification_mailer.rb` | `app/mailers/notification_mailer.rb` | ActionMailer |
| Mailer views | `app/mailers/views/notification_mailer/*.text.erb` | `app/views/notification_mailer/*.text.erb` | Rails convention |
| Schema | `schema/migrations/*.rb` (27) | `db/migrate/*.rb` + `db/schema.rb` | Timestamped filenames |

**New files:**
- `config/locales/ru.yml`, `config/locales/en.yml` — all platform UI copy
- `app/controllers/concerns/authentication.rb` — the ~4-line auth seam
- `app/controllers/concerns/locale_selection.rb` — per-request locale resolution
- `features/support/env.rb` — rewritten for Capybara
- `features/step_definitions/*.rb` — 19 step files rewritten (currently `features/*/steps/*_steps.rb`)

**Note:** `app/controllers/secutity_filters.rb` is a misspelling in the current repo. It becomes `app/controllers/concerns/security_filters.rb` at Task 8.

---

### Task 1: Rails skeleton on Ruby 3.3

**Files:**
- Create: `Gemfile`, `config/application.rb`, `config/boot.rb`, `config/environments/development.rb`, `config/environments/test.rb`, `config/environments/production.rb`, `bin/rails`, `Rakefile`, `.ruby-version`
- Modify: `config/database.yml`
- Test: `spec/rails_boot_spec.rb`

**Interfaces:**
- Produces: a bootable Rails application named `EncounterEngine`; `Rails.application`, `Rails.env`, `Rails.root` available to every later task.

- [ ] **Step 1: Create the branch and a reference worktree**

```bash
git checkout -b modernize/rails
git worktree add ../encounter-engine-merb master
```

`../encounter-engine-merb` stays on the working Merb app. Consult it whenever behaviour is unclear; it is the oracle.

- [ ] **Step 2: Generate a Rails skeleton in a scratch directory**

```bash
cd /tmp
gem install rails -v '~> 8.0'
rails new ee-skeleton --database=sqlite3 --skip-test --skip-system-test \
  --skip-action-cable --skip-action-mailbox --skip-action-text --skip-jbuilder
```

- [ ] **Step 3: Copy the skeleton files that do not collide**

```bash
cd /home/mezinster/encounter-engine
cp /tmp/ee-skeleton/config/boot.rb config/boot.rb
cp /tmp/ee-skeleton/config/application.rb config/application.rb
cp /tmp/ee-skeleton/Rakefile Rakefile
cp -r /tmp/ee-skeleton/bin/rails bin/rails
chmod +x bin/rails
rm -f config/init.rb config/rack.rb
rm -f config/environments/rake.rb config/environments/staging.rb
```

`config/router.rb` stays for now — Task 7 replaces it with `config/routes.rb`.

- [ ] **Step 4: Write `config/application.rb`**

```ruby
require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

module EncounterEngine
  class Application < Rails::Application
    config.load_defaults 8.0

    # Platform copy is translated; game content is not. See config/locales.
    config.i18n.default_locale = :ru
    config.i18n.available_locales = [:ru, :en]
    config.i18n.fallbacks = [:ru]

    # Each deployment serves one city, so the zone is per-instance, matching
    # the TZ variable create-heroku-instance already sets.
    config.time_zone = ENV.fetch("TZ", "UTC")
    config.active_record.default_timezone = :utc
  end
end
```

- [ ] **Step 5: Write `Gemfile`**

```ruby
source "https://rubygems.org"

ruby "3.3.6"

gem "rails", "~> 8.0.0"
gem "sqlite3", "~> 2.0", group: [:development, :test]
gem "pg", group: :production
gem "puma"
gem "acts_as_list"

group :development, :test do
  gem "rspec-rails", "~> 7.0"
  gem "pry"
  gem "pry-byebug"
end

group :test do
  gem "cucumber-rails", require: false
  gem "capybara"
end
```

`unicode_utils`, `thin`, `merb-*` and `merb_activerecord` are all gone. Task 5 explains why `unicode_utils` is not needed.

- [ ] **Step 6: Set the Ruby version and install**

```bash
echo "3.3.6" > .ruby-version
rbenv install -s 3.3.6
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
gem install bundler
bundle install
```

- [ ] **Step 7: Write `config/database.yml`**

```yaml
default: &default
  adapter: sqlite3
  pool: 5
  timeout: 5000
  encoding: utf8

development:
  <<: *default
  database: db/development.sqlite3

test:
  <<: *default
  database: db/test.sqlite3

production:
  adapter: postgresql
  encoding: unicode
  url: <%= ENV["DATABASE_URL"] %>
```

Note the key change from the Merb file: keys are plain strings, not symbols (`:development:`), and test is a real file rather than `:memory:` so Cucumber and RSpec can share a prepared schema.

- [ ] **Step 8: Write the failing boot test**

```ruby
# spec/rails_boot_spec.rb
require "rails_helper"

RSpec.describe "Rails application" do
  it "boots with the expected name" do
    expect(Rails.application.class.module_parent_name).to eq("EncounterEngine")
  end

  it "defaults to Russian" do
    expect(I18n.default_locale).to eq(:ru)
  end

  it "offers Russian and English" do
    expect(I18n.available_locales).to contain_exactly(:ru, :en)
  end
end
```

- [ ] **Step 9: Generate the RSpec harness and run the test to see it fail**

```bash
bin/rails generate rspec:install
bundle exec rspec spec/rails_boot_spec.rb
```

Expected: FAIL — `rails_helper` cannot load, because `config/environment.rb` does not exist yet.

- [ ] **Step 10: Create `config/environment.rb` and the three environment files**

```ruby
# config/environment.rb
require_relative "application"
Rails.application.initialize!
```

```ruby
# config/environments/test.rb
Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.action_dispatch.show_exceptions = :none
  config.action_controller.allow_forgery_protection = false
  config.action_mailer.delivery_method = :test
  config.active_support.deprecation = :stderr

  # The 59 feature files assert Russian UI copy. Pinning the locale here is
  # what lets them stay byte-identical while the app becomes translatable.
  config.i18n.default_locale = :ru
end
```

```ruby
# config/environments/development.rb
Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_mailer.delivery_method = :test
  config.active_support.deprecation = :log
end
```

```ruby
# config/environments/production.rb
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.force_ssl = true
  config.log_level = :info
  config.action_mailer.delivery_method = :smtp
  config.i18n.default_locale = ENV.fetch("DEFAULT_LOCALE", "ru").to_sym
end
```

- [ ] **Step 11: Run the test to verify it passes**

```bash
bundle exec rspec spec/rails_boot_spec.rb
```

Expected: PASS, 3 examples, 0 failures.

- [ ] **Step 12: Commit**

```bash
git add Gemfile Gemfile.lock config bin Rakefile .ruby-version spec/rails_boot_spec.rb spec/rails_helper.rb spec/spec_helper.rb
git commit -m "Add Rails 8 skeleton on Ruby 3.3"
```

---

### Task 2: Port the schema

**Files:**
- Create: `db/migrate/` (27 files), `db/schema.rb`
- Delete: `schema/migrations/` (27 files), `lib/active_record_helper.rb`
- Test: `spec/schema_spec.rb`

**Interfaces:**
- Produces: all 13 tables (`answers`, `game_entries`, `game_passings`, `games`, `hints`, `invitations`, `levels`, `logs`, `questions`, `schema_migrations`, `sqlite_sequence`, `teams`, `users`) reachable through ActiveRecord.

- [ ] **Step 1: Write the failing schema test**

```ruby
# spec/schema_spec.rb
require "rails_helper"

RSpec.describe "database schema" do
  EXPECTED_TABLES = %w[
    answers game_entries game_passings games hints
    invitations levels logs questions teams users
  ].freeze

  it "creates every table the application needs" do
    expect(ActiveRecord::Base.connection.tables).to include(*EXPECTED_TABLES)
  end

  it "keeps answered_questions on game_passings as text" do
    column = ActiveRecord::Base.connection.columns(:game_passings)
                               .find { |c| c.name == "answered_questions" }
    expect(column.type).to eq(:text)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/schema_spec.rb
```

Expected: FAIL — no tables exist.

- [ ] **Step 3: Rename the 27 migrations to Rails timestamp format**

Merb numbers migrations `001_..._migration.rb`; Rails needs `YYYYMMDDHHMMSS_...rb` and a class name matching the filename. Run:

```bash
mkdir -p db/migrate
i=0
for f in $(ls schema/migrations/*.rb | sort); do
  base=$(basename "$f" .rb)
  # Keep the _migration suffix. Stripping it yields class names like User and
  # Team that collide with the models of the same name: with eager_load on,
  # app/models loads first and reopening `class User` with a different
  # superclass raises TypeError. The Merb originals kept the suffix
  # (TeamMigration, LogMigration) for exactly this reason.
  name=$(echo "$base" | sed -E 's/^[0-9]+_//')
  ts=$(date -u -d "2009-01-01 00:00:00 UTC + $i minute" +%Y%m%d%H%M%S)
  cp "$f" "db/migrate/${ts}_${name}.rb"
  i=$((i+1))
done
```

The 2009 base date keeps them ordered before any migration written from now on.

- [ ] **Step 4: Fix each migration's class name and superclass**

Every file needs its class renamed to the CamelCase of its new filename and its superclass version-pinned. For example `db/migrate/20090101000000_initial.rb`:

```ruby
class Initial < ActiveRecord::Migration[4.2]
  def self.up
    create_table :users do |t|
      t.string :nickname
      t.string :email
      t.timestamps
    end
  end

  def self.down
    drop_table :users
  end
end
```

Apply the same two edits to all 27: `class <CamelCaseOfFilename> < ActiveRecord::Migration[4.2]`. Pinning `[4.2]` preserves the original semantics rather than silently adopting Rails 8 defaults.

- [ ] **Step 5: Run the migrations and dump the schema**

```bash
bin/rails db:create db:migrate
bin/rails db:test:prepare
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
bundle exec rspec spec/schema_spec.rb
```

Expected: PASS.

- [ ] **Step 7: Delete the Merb schema machinery**

`lib/active_record_helper.rb` replayed every migration from zero at spec load. Rails maintains `db/schema.rb` and `db:test:prepare`, so it goes. This also removes the shared-state hazard where rows leaked between examples.

```bash
git rm -r schema/migrations lib/active_record_helper.rb
```

- [ ] **Step 8: Configure per-example transactional cleanup**

```ruby
# spec/rails_helper.rb — inside RSpec.configure
config.use_transactional_fixtures = true
```

This is a behaviour change from Merb and a deliberate one: the old suite rebuilt the database once per run, which is why `Answer`'s uniqueness validation collided across examples.

- [ ] **Step 9: Commit**

```bash
git add db spec/schema_spec.rb spec/rails_helper.rb
git commit -m "Port 27 migrations to db/migrate and drop the Merb schema helper"
```

---

### Task 3: i18n foundation

**Files:**
- Create: `config/locales/ru.yml`, `config/locales/en.yml`, `app/controllers/concerns/locale_selection.rb`
- Test: `spec/i18n_spec.rb`

**Interfaces:**
- Produces: `LocaleSelection#set_locale` (a `before_action`), and the locale file structure every later task adds keys to.

- [ ] **Step 1: Write the failing i18n test**

```ruby
# spec/i18n_spec.rb
require "rails_helper"

RSpec.describe "internationalization" do
  it "has the same keys in every locale file" do
    def leaf_keys(hash, prefix = "")
      hash.flat_map do |key, value|
        path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
        value.is_a?(Hash) ? leaf_keys(value, path) : [path]
      end
    end

    ru = leaf_keys(YAML.load_file(Rails.root.join("config/locales/ru.yml")).fetch("ru"))
    en = leaf_keys(YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en"))

    expect(en.sort).to eq(ru.sort)
  end

  it "falls back to Russian for a missing English key" do
    I18n.with_locale(:en) do
      expect(I18n.t("game.not_started")).to be_present
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/i18n_spec.rb
```

Expected: FAIL — the locale files do not exist.

- [ ] **Step 3: Create the two locale files with the initial keys**

```yaml
# config/locales/ru.yml
ru:
  game:
    not_started: "Нельзя играть в игру до её начала. И вообще, где вы достали эту ссылку? :-)"
    already_in_team: "Вы уже являетесь членом команды"
```

```yaml
# config/locales/en.yml
en:
  game:
    not_started: "The game has not started yet. Where did you even get this link? :-)"
    already_in_team: "You are already a member of a team"
```

Every later task appends to both files. The first test above is what stops them drifting apart.

- [ ] **Step 4: Write the locale-selection concern**

```ruby
# app/controllers/concerns/locale_selection.rb
module LocaleSelection
  extend ActiveSupport::Concern

  included do
    before_action :set_locale
    around_action :use_locale
  end

  private

  # Precedence: explicit ?locale= (lets an organiser preview), then the signed-in
  # user's stored preference, then the instance default from DEFAULT_LOCALE.
  # Game content is never translated, so this only affects platform chrome.
  def set_locale
    @locale = requested_locale || current_user_locale || I18n.default_locale
  end

  def use_locale(&block)
    I18n.with_locale(@locale, &block)
  end

  def requested_locale
    candidate = params[:locale].presence&.to_sym
    candidate if I18n.available_locales.include?(candidate)
  end

  def current_user_locale
    return nil unless respond_to?(:current_user, true) && current_user

    candidate = current_user.locale.presence&.to_sym
    candidate if I18n.available_locales.include?(candidate)
  end
end
```

- [ ] **Step 5: Add the `locale` column to users**

```bash
bin/rails generate migration AddLocaleToUsers locale:string
bin/rails db:migrate db:test:prepare
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
bundle exec rspec spec/i18n_spec.rb
```

Expected: PASS, 2 examples, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add config/locales app/controllers/concerns/locale_selection.rb db spec/i18n_spec.rb
git commit -m "Add i18n foundation: locale files, fallbacks and per-request selection"
```

---

### Task 4: Port the 11 models

**Files:**
- Modify: `app/models/{answer,game,game_entry,game_passing,hint,invitation,level,log,question,team,user}.rb`
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`
- Test: the existing 49 files under `spec/models/`

**Interfaces:**
- Consumes: schema from Task 2, locale files from Task 3.
- Produces: all model classes with unchanged public API — `Game#started?`, `Game#created_by?`, `GamePassing#check_answer!`, `GamePassing#all_questions_answered?`, `Question#correct_answer`, `Question#matches_any_answer`, `Level#correct_answer`, `User#member_of_any_team?`.

- [ ] **Step 1: Run the model specs to see them fail**

```bash
bundle exec rspec spec/models/
```

Expected: FAIL — `uninitialized constant Game`, and the specs still require `spec_helper.rb` by relative path.

- [ ] **Step 2: Repoint every spec at `rails_helper`**

```bash
grep -rl "spec_helper.rb" spec/ | xargs sed -i \
  "s|require File.join(File.dirname(__FILE__), '..', '..', 'spec_helper.rb')|require \"rails_helper\"|; \
   s|require File.join(File.dirname(__FILE__), '..', 'spec_helper.rb')|require \"rails_helper\"|"
```

- [ ] **Step 3: Move the validation messages into locale files**

Merb-era models embed Russian in `:message`. Rails resolves messages from locale files by key, which is what makes them translatable. For `app/models/user.rb`:

```ruby
class User < ApplicationRecord
  belongs_to :team, optional: true
  has_many :created_games, class_name: "Game", foreign_key: "author_id"

  validates :email, presence: true, uniqueness: true,
                    format: { with: /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\z/i }
  validates :nickname, presence: true, uniqueness: true
  validates :password, length: { minimum: 4 }, confirmation: true, if: :password_required?

  def member_of_any_team?
    !!team
  end
end
```

with:

```yaml
# config/locales/ru.yml (append under ru:)
  activerecord:
    errors:
      models:
        user:
          attributes:
            email:
              blank: "Не введён e-mail"
              taken: "Пользователь с таким адресом уже зарегистрирован"
              invalid: "Неправильный формат поля e-mail"
            nickname:
              blank: "Вы не ввели имя"
              taken: "Пользователь с таким именем уже зарегистрирован"
            password:
              too_short: "Слишком короткий пароль (минимум 4 символа)"
              confirmation: "Пароль и его подтверждение не совпадают"
```

```yaml
# config/locales/en.yml (append under en:)
  activerecord:
    errors:
      models:
        user:
          attributes:
            email:
              blank: "E-mail is required"
              taken: "That address is already registered"
              invalid: "That e-mail address is not valid"
            nickname:
              blank: "Name is required"
              taken: "That name is already taken"
            password:
              too_short: "Password is too short (minimum 4 characters)"
              confirmation: "Password and confirmation do not match"
```

- [ ] **Step 4: Repeat for `game.rb`, `answer.rb`, `level.rb`, `team.rb`, `invitation.rb`**

Their current messages, verbatim, are the values to move: `"Вы не ввели описание"`, `"Диапазон количества команд от 1 до 10000"`, `"Вы выбрали дату из прошлого. Так нельзя :-)"`, `"Количество команд, подавших заявку превышает заданное число"`, `"Вы не ввели вариант кода"`, `"Такой код уже есть в задании"`, `"Вы не ввели название"`. Each becomes an `activerecord.errors.models.<model>.attributes.<attr>.<error_type>` key in both files. Custom `validate` methods use `errors.add(:attr, :symbolic_key)` rather than a literal string.

- [ ] **Step 5: Declare the serialized column explicitly**

```ruby
# app/models/game_passing.rb
class GamePassing < ApplicationRecord
  # Rails 7.1+ requires the coder to be explicit. YAML preserves the existing
  # column contents; changing it would strand every row already written.
  serialize :answered_questions, coder: YAML, type: Array

  belongs_to :team
  belongs_to :game
  belongs_to :current_level, class_name: "Level"

  def answered_questions
    self[:answered_questions] = [] if self[:answered_questions].nil?
    self[:answered_questions]
  end
end
```

`type: Array` makes Rails default the attribute to `[]`, which is what the hand-rolled reader above was compensating for. Keep both until the specs confirm the default applies on unsaved records, then delete the reader if `spec/models/game_passing/answered_questions_spec.rb` still passes without it.

- [ ] **Step 6: Run the model specs**

```bash
bundle exec rspec spec/models/
```

Expected: PASS. If a message assertion fails, the locale key is wrong — compare against `../encounter-engine-merb`.

- [ ] **Step 7: Run the i18n parity test**

```bash
bundle exec rspec spec/i18n_spec.rb
```

Expected: PASS. A failure here means a key was added to `ru.yml` but not `en.yml`.

- [ ] **Step 8: Commit**

```bash
git add app/models config/locales spec
git commit -m "Port models to Rails and move validation messages into locale files"
```

---

### Task 5: Replace unicode_utils with native Unicode casing

**Files:**
- Modify: `app/models/question.rb`
- Delete: `lib/ee_strings.rb`
- Test: `spec/models/question/matches_any_answer_spec.rb`

**Interfaces:**
- Produces: `Question#matches_any_answer(value)` — case-insensitive across every script, whitespace-insensitive.

- [ ] **Step 1: Write the failing multilingual test**

```ruby
# spec/models/question/matches_any_answer_spec.rb
require "rails_helper"

RSpec.describe Question, "#matches_any_answer" do
  def question_with(code)
    level = create_level(correct_answer: code)
    level.questions.first
  end

  it "ignores case for Latin codes" do
    expect(question_with("code1").matches_any_answer("CODE1")).to be true
  end

  it "ignores case for Cyrillic codes" do
    expect(question_with("код1").matches_any_answer("КОД1")).to be true
  end

  it "ignores case for Greek codes" do
    expect(question_with("κωδικός").matches_any_answer("ΚΩΔΙΚΌΣ")).to be true
  end

  it "ignores surrounding whitespace" do
    expect(question_with("code1").matches_any_answer("  code1  ")).to be true
  end

  it "still rejects a genuinely different code" do
    expect(question_with("code1").matches_any_answer("code2")).to be false
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/models/question/matches_any_answer_spec.rb
```

Expected: FAIL — `undefined method 'upcase_utf8_cyr'`, because `lib/ee_strings.rb` is no longer autoloaded under Rails.

- [ ] **Step 3: Use native `String#upcase`**

```ruby
# app/models/question.rb
class Question < ApplicationRecord
  belongs_to :level, optional: true
  has_many :answers

  def correct_answer=(value)
    answers.build(value: value)
  end

  def correct_answer
    answers.first&.value
  end

  # unicode_utils existed because Ruby 1.9's String#upcase was ASCII-only.
  # Ruby 2.4 made it full Unicode, so the gem and lib/ee_strings.rb are dead
  # weight. This matters for a multilingual platform: codes are author-authored
  # and may be in any script.
  def matches_any_answer(value)
    normalized = normalize(value)
    answers.any? { |answer| normalize(answer.value) == normalized }
  end

  private

  def normalize(value)
    value.to_s.strip.upcase
  end
end
```

- [ ] **Step 4: Delete the monkey patch**

```bash
git rm lib/ee_strings.rb
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rspec spec/models/question/matches_any_answer_spec.rb
```

Expected: PASS, 5 examples, 0 failures.

- [ ] **Step 6: Record the Turkish caveat in the locale docs**

Append to `config/locales/README.md` (create it):

```markdown
# Locale notes

`Question#matches_any_answer` uses `String#upcase`, which is locale-independent.
Turkish and Azeri are the known exception: dotless `ı` uppercases to `I` rather
than `İ`. If either locale is ever added, that method needs `upcase(:turkic)`
selected from the game's locale, not the viewer's.
```

- [ ] **Step 7: Commit**

```bash
git add app/models/question.rb config/locales/README.md spec
git rm --cached lib/ee_strings.rb 2>/dev/null || true
git commit -m "Use native Unicode casing for answer codes and drop unicode_utils"
```

---

> **Execution order note:** run Task 7 (Routes) *before* Task 6. Task 6's `SessionsController`
> references `login_path`, `dashboard_path` and `root_path`, and its spec issues `post :create`,
> all of which need routes to exist. Task 7 depends on nothing — routing specs assert route
> recognition, not controller existence — so it is safe to run first. The task numbering is left
> as written to keep the briefs stable.

### Task 6: Authentication

**Files:**
- Create: `app/controllers/concerns/authentication.rb`, `app/controllers/sessions_controller.rb`, `app/views/sessions/new.html.erb`
- Modify: `app/models/user.rb`
- Delete: `.gitmodules` entry for `vendor/merb-auth`
- Test: `spec/controllers/sessions_controller_spec.rb`

**Interfaces:**
- Consumes: `User` from Task 4.
- Produces: `Authentication#current_user` → `User` or `nil`; `#logged_in?` → boolean; `#require_authentication!` (a `before_action` that raises `Unauthenticated`); `User#authenticate(password)` → boolean.

- [ ] **Step 1: Write the failing session test**

```ruby
# spec/controllers/sessions_controller_spec.rb
require "rails_helper"

RSpec.describe SessionsController, type: :controller do
  let!(:user) do
    User.create!(nickname: "iv", email: "iv@diesel.kg",
                 password: "1234", password_confirmation: "1234")
  end

  it "signs a user in with correct credentials" do
    post :create, params: { email: "iv@diesel.kg", password: "1234" }
    expect(session[:user_id]).to eq(user.id)
  end

  it "rejects a wrong password" do
    post :create, params: { email: "iv@diesel.kg", password: "wrong" }
    expect(session[:user_id]).to be_nil
  end

  it "signs a user out" do
    session[:user_id] = user.id
    delete :destroy
    expect(session[:user_id]).to be_nil
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/controllers/sessions_controller_spec.rb
```

Expected: FAIL — `uninitialized constant SessionsController`.

- [ ] **Step 3: Add password hashing to `User`**

merb-auth stored a salted SHA1 in `crypted_password` with a `salt` column. Both columns already exist, so keep the algorithm to avoid invalidating every existing password:

```ruby
# app/models/user.rb — append
require "digest/sha1"

class User < ApplicationRecord
  attr_accessor :password, :password_confirmation

  before_save :encrypt_password, if: -> { password.present? }

  def authenticate(candidate)
    return false if crypted_password.blank?

    self.class.encrypt(candidate, salt) == crypted_password
  end

  def self.encrypt(candidate, salt)
    Digest::SHA1.hexdigest("--#{salt}--#{candidate}--")
  end

  def password_required?
    crypted_password.blank? || password.present?
  end

  private

  def encrypt_password
    self.salt ||= Digest::SHA1.hexdigest("--#{Time.now.utc}--#{nickname}--")
    self.crypted_password = self.class.encrypt(password, salt)
  end
end
```

Confirm the digest format against `vendor/merb-auth/merb-auth-more/lib/merb-auth-more/mixins/salted_user.rb` in the reference worktree before running. If it differs, match it exactly — every existing user's password depends on it.

- [ ] **Step 4: Write the authentication concern**

```ruby
# app/controllers/concerns/authentication.rb
module Authentication
  extend ActiveSupport::Concern

  class Unauthenticated < StandardError; end
  class Unauthorized < StandardError; end

  private

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:user_id] && User.find_by(id: session[:user_id])
  end

  def logged_in?
    !!current_user
  end

  # Must run before any filter that touches current_user. In the Merb app the
  # order was inverted, so a guest hitting a play URL got a 500 rather than a
  # login prompt.
  def require_authentication!
    raise Unauthenticated unless logged_in?
  end
end
```

- [ ] **Step 5: Write the sessions controller**

```ruby
# app/controllers/sessions_controller.rb
class SessionsController < ApplicationController
  def new; end

  def create
    user = User.find_by(email: params[:email])

    if user&.authenticate(params[:password])
      session[:user_id] = user.id
      redirect_to dashboard_path
    else
      flash.now[:error] = t("sessions.invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path
  end
end
```

Add to both locale files: `sessions.invalid_credentials` — ru `"Неправильный e-mail или пароль"`, en `"Wrong e-mail or password"`.

- [ ] **Step 6: Run the test to verify it passes**

```bash
bundle exec rspec spec/controllers/sessions_controller_spec.rb
```

Expected: PASS, 3 examples, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add app/controllers app/models/user.rb app/views/sessions config/locales spec
git commit -m "Replace the merb-auth slices with a session-based auth concern"
```

---

### Task 7: Routes

**Files:**
- Create: `config/routes.rb`
- Delete: `config/router.rb`
- Test: `spec/routing_spec.rb`

**Interfaces:**
- Produces: named helpers used by every view — `dashboard_path`, `game_path`, `games_path`, `new_game_path`, `edit_game_path`, `show_current_level_path(game_id)`, `post_answer_path(game_id)`, `game_stats_path`, `show_live_channel_path`, `show_level_log_path`, `team_room_path`, `login_path`, `logout_path`, `signup_path`.

- [ ] **Step 1: Write the failing routing test**

```ruby
# spec/routing_spec.rb
require "rails_helper"

RSpec.describe "routing" do
  it "keeps the gameplay URLs byte-identical to the Merb app" do
    expect(get: "/play/7").to route_to(
      controller: "game_passings", action: "show_current_level", game_id: "7"
    )
    expect(post: "/play/7").to route_to(
      controller: "game_passings", action: "post_answer", game_id: "7"
    )
    expect(get: "/play/7/tip").to route_to(
      controller: "game_passings", action: "get_current_level_tip", game_id: "7"
    )
  end

  it "keeps the nested authoring routes" do
    expect(get: "/games/3/levels/9/hints").to route_to(
      controller: "hints", action: "index", game_id: "3", level_id: "9"
    )
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/routing_spec.rb
```

Expected: FAIL — no routes are defined.

- [ ] **Step 3: Write `config/routes.rb`**

```ruby
Rails.application.routes.draw do
  root to: "index#index"

  get    "/login",  to: "sessions#new",     as: :login
  post   "/login",  to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout
  get    "/signup", to: "users#new",        as: :signup

  get "/dashboard", to: "dashboard#index", as: :dashboard
  get "/team-room", to: "team_room#index", as: :team_room

  resources :users
  resources :teams
  resources :invitations

  resources :games do
    resources :levels do
      resources :hints
      resources :questions do
        resources :answers
      end

      member do
        get :move_up
        get :move_down
      end
    end
  end

  # Gameplay paths are load-bearing: they appear in features and in links
  # players have bookmarked. Keep them exactly as Merb served them.
  get  "/play/:game_id/tip", to: "game_passings#get_current_level_tip", as: :get_current_level_tip
  get  "/play/:game_id",     to: "game_passings#show_current_level",    as: :show_current_level
  post "/play/:game_id",     to: "game_passings#post_answer",           as: :post_answer

  get "/stats/:action/:game_id", controller: "game_passings", as: :game_stats
  get "/logs/livechannel/:game_id",     to: "logs#show_live_channel", as: :show_live_channel
  get "/logs/level/:game_id/:team_id",  to: "logs#show_level_log",    as: :show_level_log
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/routing_spec.rb
```

Expected: PASS, 2 examples, 0 failures.

- [ ] **Step 5: Delete the Merb router and commit**

```bash
git rm config/router.rb
git add config/routes.rb spec/routing_spec.rb
git commit -m "Port the router to config/routes.rb, preserving all URLs"
```

---

### Task 8: Controllers

**Files:**
- Create: `app/controllers/application_controller.rb`, `app/controllers/concerns/security_filters.rb`, and 16 `*_controller.rb` files
- Delete: the 17 files in `app/controllers/` that lack the `_controller` suffix
- Test: the existing files under `spec/controllers/`

**Interfaces:**
- Consumes: `Authentication` (Task 6), `LocaleSelection` (Task 3), models (Task 4), routes (Task 7).
- Produces: one controller per route defined in Task 7.

- [ ] **Step 1: Run the controller specs to see them fail**

```bash
bundle exec rspec spec/controllers/
```

Expected: FAIL — `uninitialized constant GamesController`.

- [ ] **Step 2: Write `ApplicationController`**

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication
  include LocaleSelection

  rescue_from Authentication::Unauthenticated, with: :deny_unauthenticated
  rescue_from Authentication::Unauthorized,    with: :deny_unauthorized

  helper_method :current_user, :logged_in?

  private

  def deny_unauthenticated
    respond_to do |format|
      format.html { redirect_to login_path, alert: t("errors.unauthenticated") }
    end
  end

  def deny_unauthorized(exception)
    render plain: exception.message.presence || t("errors.unauthorized"),
           status: :unauthorized
  end
end
```

Add `errors.unauthenticated` and `errors.unauthorized` to both locale files. The Russian values come from the Merb app's exception views in the reference worktree.

- [ ] **Step 3: Port `GamesController`**

```ruby
# app/controllers/games_controller.rb
class GamesController < ApplicationController
  before_action :require_authentication!, except: [:index, :show]
  before_action :find_game, only: [:show, :edit, :update, :destroy, :end_game]
  before_action :ensure_author, only: [:edit, :update]
  before_action :ensure_game_was_not_started, only: [:edit, :update]

  def index
    @games = if params[:user_id].present?
               User.find(params[:user_id]).created_games
             else
               Game.non_drafts
             end
  end

  def new
    @game = Game.new
  end

  def create
    @game = Game.new(game_params.merge(author: current_user))

    if @game.save
      redirect_to @game
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @game_entries = GameEntry.of_game(@game).with_status("new")
    @teams = GameEntry.of_game(@game).with_status("accepted").map(&:team)
  end

  def edit; end

  def update
    if @game.update(game_params)
      redirect_to @game
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  # Merb passed params[:game] straight to update_attributes. Strong parameters
  # are the Rails equivalent and close that hole.
  def game_params
    params.require(:game).permit(:name, :description, :starts_at,
                                 :max_team_number, :registration_deadline,
                                 :is_testing, :is_draft)
  end

  def find_game
    @game = Game.find(params[:id])
  end

  def ensure_author
    raise Authentication::Unauthorized unless @game.created_by?(current_user)
  end

  def ensure_game_was_not_started
    raise Authentication::Unauthorized if @game.started?
  end
end
```

- [ ] **Step 4: Port `GamePassingsController` with the filter order corrected**

```ruby
# app/controllers/game_passings_controller.rb
class GamePassingsController < ApplicationController
  # Authentication first: find_team dereferences current_user, so running it
  # before this filter turned a guest's request into a 500.
  before_action :require_authentication!, except: [:index, :show_results]
  before_action :find_game
  before_action :find_team,                    except: [:index, :show_results]
  before_action :find_or_create_game_passing,  except: [:index, :show_results]
  before_action :ensure_game_is_started

  def show_current_level
    @level = @game_passing.current_level
  end

  def post_answer
    # params[:answer] is a bare string. Guard the type: a crafted request
    # sending answer[value]= made the Merb app raise on String#strip.
    answer = params[:answer]
    answer = answer.is_a?(String) ? answer : ""

    @correct = @game_passing.check_answer!(answer)
    render :show_current_level
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_team
    @team = current_user.team
  end

  def find_or_create_game_passing
    @game_passing = GamePassing.of(@team, @game) ||
                    GamePassing.create!(game: @game, team: @team,
                                        current_level: @game.levels.first)
  end

  def ensure_game_is_started
    return if @game.is_testing?
    raise Authentication::Unauthorized, t("game.not_started") unless @game.started?
  end
end
```

- [ ] **Step 5: Port the remaining 14 controllers**

One file each, same shape: `UsersController`, `TeamsController`, `InvitationsController`, `LevelsController`, `QuestionsController`, `AnswersController`, `HintsController`, `DashboardController`, `IndexController`, `LogsController`, `TeamRoomController`, `GameEntriesController`, `ExceptionsController`. Rules that apply to all of them:

- `before` → `before_action`; `:exclude` → `:except`.
- Delete every bare `render` at the end of an action; Rails renders implicitly.
- `params[:model]` → a private `model_params` method using `require`/`permit`.
- `redirect resource(@x)` → `redirect_to @x`.
- Any user-visible string → `t("...")` plus a key in both locale files.
- `app/controllers/secutity_filters.rb` becomes `app/controllers/concerns/security_filters.rb`, with the spelling corrected, and is `include`d where it was previously inherited.

- [ ] **Step 6: Run the controller specs**

```bash
bundle exec rspec spec/controllers/
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/controllers config/locales spec
git commit -m "Port all 17 controllers to Rails with strong parameters"
```

---

### Task 9: Views and layout

**Files:**
- Modify: 53 files under `app/views/`, renamed `*.erb` → `*.html.erb`
- Create: `app/views/layouts/application.html.erb`
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`
- Test: `spec/views/i18n_coverage_spec.rb`

**Interfaces:**
- Consumes: route helpers (Task 7), controllers (Task 8), `t`/`l` from Rails I18n.

- [ ] **Step 1: Write the failing hardcoded-copy test**

```ruby
# spec/views/i18n_coverage_spec.rb
require "rails_helper"

RSpec.describe "view templates" do
  it "contain no hardcoded Cyrillic copy" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].select do |path|
      # Skip mailer templates; Task 10 covers those.
      next false if path.include?("notification_mailer")

      File.read(path).match?(/[А-Яа-яЁё]/)
    end

    expect(offenders).to be_empty,
      "hardcoded Russian remains in:\n#{offenders.join("\n")}"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/views/i18n_coverage_spec.rb
```

Expected: FAIL, listing roughly 40 template files (133 strings).

- [ ] **Step 3: Rename every template**

```bash
find app/views -name '*.erb' ! -name '*.html.erb' -exec bash -c \
  'git mv "$0" "${0%.erb}.html.erb"' {} \;
```

- [ ] **Step 4: Write the layout**

```erb
<%# app/views/layouts/application.html.erb %>
<!DOCTYPE html>
<html lang="<%= I18n.locale %>">
  <head>
    <title><%= t("layout.title") %></title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <%= csrf_meta_tags %>
    <%= stylesheet_link_tag "master" %>
  </head>
  <body>
    <div id="header-container">
      <div id="header">
        <%= link_to t("layout.home"), root_path, class: "home-link" %>
        <%= l(Time.current, format: :short) %>
        <%= render "shared/locale_switcher" %>
      </div>
    </div>

    <div id="left-container"><div class="left"><%= yield :sidebar %></div></div>
    <div id="main-container"><div id="main"><%= yield %></div></div>
  </body>
</html>
```

The `lang` attribute is new and required: screen readers and browser translation both need it, and it was impossible to set correctly before.

- [ ] **Step 5: Extract copy from every template**

Work file by file. Each Russian literal becomes a `t()` call with a key named for its location, and the literal moves to `ru.yml` verbatim with an English sibling in `en.yml`. Example, from `app/views/games/new.html.erb`:

```erb
<%# before %>
<label for="game_name">Название</label>

<%# after %>
<label for="game_name"><%= t("games.form.name") %></label>
```

```yaml
# ru.yml
  games:
    form:
      name: "Название"
      description: "Описание"
      max_team_number: "Максимальное количество команд"
      submit: "Создать игру"
```

```yaml
# en.yml
  games:
    form:
      name: "Title"
      description: "Description"
      max_team_number: "Maximum number of teams"
      submit: "Create game"
```

**Do not translate:** `@game.name`, `@level.text`, `@hint.text`, `@question.correct_answer`, team and user names. Those are data.

- [ ] **Step 6: Localize every date and time**

Replace bare interpolation with the `l` helper:

```erb
<%# before %>
<%= @game.starts_at %>

<%# after %>
<%= l(@game.starts_at, format: :long) if @game.starts_at %>
```

and define the formats:

```yaml
# ru.yml
  time:
    formats:
      short: "%d.%m.%Y %H:%M"
      long: "%d %B %Y, %H:%M"
```

```yaml
# en.yml
  time:
    formats:
      short: "%Y-%m-%d %H:%M"
      long: "%B %-d, %Y at %H:%M"
```

Russian month names require `date.month_names` in `ru.yml`; copy them from the `rails-i18n` gem's `ru.yml` rather than typing them, since they need genitive case.

- [ ] **Step 7: Add the locale switcher partial**

```erb
<%# app/views/shared/_locale_switcher.html.erb %>
<span class="locale-switcher">
  <% I18n.available_locales.each do |locale| %>
    <% if locale == I18n.locale %>
      <strong><%= t("locales.#{locale}") %></strong>
    <% else %>
      <%= link_to t("locales.#{locale}"), url_for(locale: locale) %>
    <% end %>
  <% end %>
</span>
```

Add `locales.ru` (`"Русский"` in both files) and `locales.en` (`"English"` in both files) — language names are conventionally not translated.

- [ ] **Step 8: Run the coverage test to verify it passes**

```bash
bundle exec rspec spec/views/i18n_coverage_spec.rb spec/i18n_spec.rb
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/views config/locales spec
git commit -m "Port views to Rails and extract all UI copy into locale files"
```

---

### Task 10: Mailers

**Files:**
- Modify: `app/mailers/notification_mailer.rb`
- Move: `app/mailers/views/notification_mailer/*.text.erb` → `app/views/notification_mailer/*.text.erb`
- Test: `spec/mailers/notification_mailer_spec.rb`

**Interfaces:**
- Consumes: `User`, `Team`, locale files.
- Produces: `NotificationMailer.welcome_letter(user, password)`, `.invitation_notification(user, team)`, `.reject_notification(user)`, `.accept_notification(user)` — each returning a `Mail::Message`.

- [ ] **Step 1: Write the failing mailer test**

```ruby
# spec/mailers/notification_mailer_spec.rb
require "rails_helper"

RSpec.describe NotificationMailer do
  let(:user) do
    User.create!(nickname: "iv", email: "iv@diesel.kg",
                 password: "1234", password_confirmation: "1234",
                 locale: "en")
  end

  it "addresses the welcome letter to the user" do
    mail = described_class.welcome_letter(user, "1234")
    expect(mail.to).to eq(["iv@diesel.kg"])
  end

  it "writes the letter in the recipient's locale, not the sender's" do
    I18n.with_locale(:ru) do
      mail = described_class.welcome_letter(user, "1234")
      expect(mail.subject).to eq(I18n.t("notification_mailer.welcome_letter.subject", locale: :en))
    end
  end
end
```

The second example is the point of this task: a Russian-speaking organiser inviting an English-speaking player must not send them Russian.

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/mailers/notification_mailer_spec.rb
```

Expected: FAIL — `NotificationMailer` still inherits `Merb::MailController`.

- [ ] **Step 3: Move the templates**

```bash
mkdir -p app/views/notification_mailer
git mv app/mailers/views/notification_mailer/welcome_letter.text.erb      app/views/notification_mailer/welcome_letter.text.erb
git mv app/mailers/views/notification_mailer/invitation_notification.text.erb app/views/notification_mailer/invitation_notification.text.erb
git mv app/mailers/views/notification_mailer/reject_notification.text.erb app/views/notification_mailer/reject_notification.text.erb
git mv app/mailers/views/notification_mailer/accept_notification.text.erb app/views/notification_mailer/accept_notification.text.erb
rmdir app/mailers/views/notification_mailer app/mailers/views
```

- [ ] **Step 4: Rewrite the mailer**

```ruby
# app/mailers/notification_mailer.rb
class NotificationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "noreply@encounter-engine.org")

  def welcome_letter(user, password)
    @user = user
    @password = password
    mail_in_recipient_locale(user, :welcome_letter)
  end

  def invitation_notification(user, team)
    @user = user
    @team = team
    mail_in_recipient_locale(user, :invitation_notification)
  end

  def reject_notification(user)
    @user = user
    mail_in_recipient_locale(user, :reject_notification)
  end

  def accept_notification(user)
    @user = user
    mail_in_recipient_locale(user, :accept_notification)
  end

  private

  # The reader's locale governs, not the sender's request locale.
  def mail_in_recipient_locale(user, template)
    locale = user.locale.presence || I18n.default_locale

    I18n.with_locale(locale) do
      mail(to: user.email,
           subject: t("notification_mailer.#{template}.subject"),
           template_name: template)
    end
  end
end
```

- [ ] **Step 5: Extract the template copy**

Each of the four `.text.erb` templates is entirely Russian prose. Move each paragraph to a locale key under `notification_mailer.<template>.body` and render with `t`, interpolating `@user.nickname`, `@password`, `@team.name` as I18n variables:

```erb
<%# app/views/notification_mailer/welcome_letter.text.erb %>
<%= t("notification_mailer.welcome_letter.body",
      nickname: @user.nickname, password: @password) %>
```

```yaml
# ru.yml
  notification_mailer:
    welcome_letter:
      subject: "Добро пожаловать!"
      body: |
        Здравствуйте, %{nickname}!
        Ваш пароль: %{password}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
bundle exec rspec spec/mailers/
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/mailers app/views/notification_mailer config/locales spec
git commit -m "Port mailers to ActionMailer and send in the recipient's locale"
```

---

### Task 11: Cucumber on Capybara — the acceptance gate

**Files:**
- Create: `features/support/env.rb` (rewritten), `features/step_definitions/*.rb` (19 files)
- Delete: `features/*/steps/*_steps.rb`, `features/steps/*_steps.rb`
- Unchanged: all 59 `features/**/*.feature`

**Interfaces:**
- Consumes: the whole application.
- Produces: a green `bundle exec cucumber` — 230 scenarios, 2,355 steps.

- [ ] **Step 1: Install cucumber-rails**

```bash
bundle exec rails generate cucumber:install
```

This writes `config/cucumber.yml` and `features/support/env.rb`. Overwrite the existing `config/cucumber.yml`; the rerun profile it generates is equivalent to the current one.

- [ ] **Step 2: Pin the locale and confirm Russian Gherkin still parses**

```ruby
# features/support/env.rb — append
require "capybara/cucumber"

Capybara.default_driver = :rack_test

# Every feature file asserts Russian UI copy, which is what keeps them
# unchanged through this migration.
Before { I18n.locale = :ru }
```

```bash
bundle exec cucumber features/games/create-game.feature --dry-run
```

Expected: the scenarios are listed with undefined steps. If the parser rejects `# language: ru`, stop — that is a blocking incompatibility and everything downstream depends on it.

- [ ] **Step 3: Run the suite to see every step undefined**

```bash
bundle exec cucumber
```

Expected: 230 scenarios, all undefined. Cucumber prints snippets for each missing step — that list is the work queue for this task.

- [ ] **Step 4: Port the navigation and form steps**

The webrat API maps almost one-to-one onto Capybara. Create `features/step_definitions/webrat_steps.rb`:

```ruby
# features/step_definitions/webrat_steps.rb
Если(/^я захожу в личный кабинет$/) do
  visit dashboard_path
end

Если(/^иду по ссылке "([^"]*)"$/) do |link|
  click_link link
end

Если(/^ввожу "([^"]*)" в поле "([^"]*)"$/) do |value, field|
  fill_in field, with: value
end

Если(/^нажимаю "([^"]*)"$/) do |button|
  click_button button
end

То(/^должен увидеть "([^"]*)"$/) do |text|
  expect(page).to have_content(text)
end

То(/^больше не должен видеть "([^"]*)"$/) do |text|
  expect(page).not_to have_content(text)
end
```

Consult `../encounter-engine-merb/features/steps/webrat_steps.rb` for the exact regexes — they must match the feature files character for character, including the Russian keywords.

- [ ] **Step 5: Port the time-travel steps**

```ruby
# features/step_definitions/time_steps.rb
Допустим(/^сейчас "([^"]*)"$/) do |fake_time|
  travel_to Time.zone.parse(fake_time)
end
```

```ruby
# features/support/time_helpers.rb
require "active_support/testing/time_helpers"
World(ActiveSupport::Testing::TimeHelpers)
After { travel_back }
```

`ActiveSupport::Testing::TimeHelpers` replaces the rspec-mocks stub on `Time.now`. It is the supported mechanism and, unlike the stub, also moves `Date.today` and `Time.zone.now`, which matters for hint countdowns.

- [ ] **Step 6: Port the remaining 17 step files**

One file per existing one, keeping filenames recognisable: `games_steps.rb`, `levels_steps.rb`, `teams_steps.rb`, `invitations_steps.rb`, `login_steps.rb`, `game-passing_steps.rb`, `hints_steps.rb`, `mail_steps.rb`, `result_steps.rb`, `before_steps.rb`. Two rules:

- `Merb::Mailer.deliveries` → `ActionMailer::Base.deliveries`
- The `Before` hook that called `ActiveRecordHelper.recreate_database!` is deleted; `cucumber-rails` wraps each scenario in a transaction.

- [ ] **Step 7: Run the suite until green**

```bash
bundle exec cucumber
```

Expected: `230 scenarios (230 passed)`, `2355 steps (2355 passed)`.

Any failure is a porting defect. Reproduce the same scenario in the reference worktree — if it passes there and fails here, the new code is wrong.

- [ ] **Step 8: Commit**

```bash
git add features config/cucumber.yml
git commit -m "Port the Cucumber suite to Capybara; 230 scenarios green"
```

---

### Task 12: Locale coverage for the platform

**Files:**
- Create: `features/i18n/switch-language.feature`, `features/step_definitions/i18n_steps.rb`
- Modify: `app/views/users/edit.html.erb`, `app/controllers/users_controller.rb`

**Interfaces:**
- Consumes: `LocaleSelection` (Task 3), the locale switcher partial (Task 9).
- Produces: a user-facing language preference persisted on `users.locale`.

This is the one task permitted to add feature files.

- [ ] **Step 1: Write the failing feature**

```gherkin
# language: en
# features/i18n/switch-language.feature
Feature: Choosing an interface language
  A platform serving several cities must let each player read the interface
  in their own language, without altering the games themselves.

  Background:
    Given a user "Iv" is registered

  Scenario: A visitor switches the interface to English
    When I go to the front page with locale "en"
    Then I should see "Log in"

  Scenario: A signed-in user saves a language preference
    Given I am logged in as Iv
    When I set my interface language to "en"
    And I go to the dashboard
    Then I should see "My games"

  Scenario: Game content is not translated
    Given a game "Котлованы Бишкека" was created by Iv
    When I go to the front page with locale "en"
    Then I should see "Котлованы Бишкека"
```

The third scenario is the important one: it pins the rule that author-written content survives a locale change untouched.

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec cucumber features/i18n/switch-language.feature
```

Expected: FAIL — undefined steps.

- [ ] **Step 3: Write the steps**

```ruby
# features/step_definitions/i18n_steps.rb
When("I go to the front page with locale {string}") do |locale|
  visit root_path(locale: locale)
end

When("I go to the dashboard") do
  visit dashboard_path
end

When("I set my interface language to {string}") do |locale|
  visit edit_user_path(@current_user)
  select I18n.t("locales.#{locale}"), from: I18n.t("users.form.locale")
  click_button I18n.t("users.form.submit")
end
```

- [ ] **Step 4: Add the preference to the user form**

```erb
<%# app/views/users/edit.html.erb — add %>
<p>
  <%= label_tag :"user_locale", t("users.form.locale") %>
  <%= select_tag "user[locale]",
        options_for_select(
          I18n.available_locales.map { |l| [t("locales.#{l}"), l] },
          @user.locale
        ) %>
</p>
```

and permit it: `params.require(:user).permit(:nickname, :email, :locale, ...)`.

- [ ] **Step 5: Run the whole suite**

```bash
bundle exec cucumber
bundle exec rspec
```

Expected: 233 scenarios green (230 original + 3 new), RSpec green.

- [ ] **Step 6: Commit**

```bash
git add features app/views/users app/controllers/users_controller.rb config/locales
git commit -m "Let users choose an interface language; pin that content is untranslated"
```

---

### Task 13: Cutover

**Files:**
- Delete: `vendor/merb/`, `vendor/merb-auth/`, `.gitmodules`, `autotest/`, `merb/`, `slices/`, `public/merb.fcgi`, `spec/spec_helpers/merb_matchers.rb`, `spec/spec_helper.rb` shims
- Modify: `.github/workflows/ci.yml`, `Procfile`, `create-heroku-instance`, `CLAUDE.md`, `.claude/skills/setup-dev/SKILL.md`, `.claude/skills/run-tests/SKILL.md`

- [ ] **Step 1: Remove the submodules**

```bash
git submodule deinit -f vendor/merb vendor/merb-auth
git rm -rf vendor/merb vendor/merb-auth
git rm -f .gitmodules
rm -rf .git/modules/vendor
```

- [ ] **Step 2: Remove the remaining Merb files**

```bash
git rm -rf autotest merb slices public/merb.fcgi
git rm -f spec/spec_helpers/merb_matchers.rb
```

The two Rack-2 shims in `spec/spec_helper.rb` (the webrat `#request` override and the `CookieJar` patch) go with it — both existed only to work around Merb.

- [ ] **Step 3: Update the Procfile**

```
web: bundle exec puma -p $PORT
```

- [ ] **Step 4: Update the provisioning script**

```bash
heroku config:set RAILS_ENV=production TZ="$2" DEFAULT_LOCALE="${3:-ru}" \
  SESSION_SECRET_KEY="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(40)')" -r $1
```

`MERB_ENV` is gone; `DEFAULT_LOCALE` is new and defaults to Russian so existing behaviour is unchanged. Document the third argument in the script's header comment.

- [ ] **Step 5: Update CI**

Replace the `container: ruby:2.6.5` line in both jobs with `container: ruby:3.3.6`, and delete the comment explaining the OpenSSL 1.1 constraint — it no longer applies. Add a third job:

```yaml
  i18n:
    name: Locale parity
    runs-on: ubuntu-latest
    container: ruby:3.3.6
    steps:
      - uses: actions/checkout@v4
      - run: gem install bundler --no-document
      - run: bundle install --jobs 4 --retry 3
      - run: bundle exec rspec spec/i18n_spec.rb spec/views/i18n_coverage_spec.rb
```

Submodule checkout can be dropped from all jobs — there are no submodules left.

- [ ] **Step 6: Rewrite the documentation**

`CLAUDE.md` currently describes Merb conventions at length; every claim in the "Merb, not Rails" section is now false and actively misleading. Replace that section, the setup steps, and the commands. Same for both skills: `setup-dev` loses the submodule and OpenSSL steps entirely, and `run-tests` gains the locale note.

- [ ] **Step 7: Verify the whole thing from a clean clone**

```bash
cd /tmp && git clone /home/mezinster/encounter-engine ee-clean && cd ee-clean
git checkout modernize/rails
bundle install
bin/rails db:setup db:test:prepare
bundle exec rspec
bundle exec cucumber
bin/rails server -p 4000 &
sleep 5 && curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4000/
```

Expected: both suites green, HTTP 200. This is the real test of Task 13 — no submodules, no OpenSSL pinning, no vendored framework.

- [ ] **Step 8: Commit and open the pull request**

```bash
git add -A
git commit -m "Remove Merb and update deployment, CI and documentation"
git push -u origin modernize/rails
gh pr create --repo mezinster/encounter-engine --base master --head modernize/rails \
  --title "Port from Merb to Rails 8 and make the platform multilingual"
```

Target the fork explicitly. This repository is a fork of `DanielVartanov/encounter-engine`, and `gh pr create` otherwise defaults its base to the upstream project.

- [ ] **Step 9: Remove the reference worktree**

```bash
git worktree remove ../encounter-engine-merb
```

Only after the pull request is green.

---

## Risks

**Password hashing must match exactly.** Task 6 reimplements merb-auth's salted SHA1. Get the digest format wrong and every existing user is locked out with no error — the login form simply rejects correct passwords. Verify against the vendored source before running, and test with a row copied from a production dump.

**Russian Gherkin support is load-bearing.** If modern Cucumber cannot parse `# language: ru`, 2,829 lines of specification stop executing and the migration loses its safety net. Task 11 Step 2 checks this before any step is written. Do not proceed past it on a failure.

**`serialize` semantics changed.** Rails 7.1 requires an explicit coder, and `answered_questions` already produced one data-loss bug during the RSpec migration. Task 4 pins `coder: YAML`; if any row fails to load, the coder is wrong and the game state of teams mid-play is at stake.

**Locale leakage into content.** The most likely i18n defect is running author-written text through `t()`, which turns a missing key into `translation missing:` in the middle of a live game. The Task 12 scenario guards the common case; be alert for it whenever a view interpolates a model attribute.

---

## Self-Review

**Spec coverage.** Merb→Rails port: Tasks 1, 2, 4, 6, 7, 8, 9, 10, 13. Internationalization: Tasks 3, 4 (validation messages), 5 (script-independent code matching), 9 (UI copy, dates), 10 (mailers), 12 (user preference), 13 (`DEFAULT_LOCALE` in provisioning, CI parity job). Acceptance gate preserved: Task 11. No requirement is unassigned.

**Placeholder scan.** No "TBD", no "similar to Task N", no "add error handling". Task 8 Step 5 and Task 9 Step 5 enumerate rules rather than repeating 14 near-identical controllers and 40 templates; both give complete worked examples plus the exact transformation rules, which is the information an implementer needs.

**Type consistency.** `current_user` returns `User` or `nil` in Tasks 6, 3 and 8. `Authentication::Unauthenticated` and `Authentication::Unauthorized` are defined in Task 6 and rescued in Task 8. `Question#matches_any_answer` keeps its Task 4 signature in Task 5. Route helper names in Task 7 match their uses in Tasks 6, 9 and 12. `NotificationMailer` method arities in Task 10 match the calls its specs make.
