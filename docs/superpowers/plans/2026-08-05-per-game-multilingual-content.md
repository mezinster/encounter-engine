# Per-Game Multilingual Content Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a game be authored in several languages so a Georgian team and a Russian team can race through the same levels simultaneously, each reading the task in their own language.

**Architecture:** Translations live in one polymorphic `content_translations` side table. The existing `games.name`, `levels.text`, `hints.text` and `questions.questions` columns keep holding the author's *primary*-language text exactly as they do today, so no existing row is rewritten and the read-only Cucumber suite is untouched. A `TranslatableContent` concern reads column-or-translation; a `ContentLocaleSelection` controller concern resolves which language a given player sees. Completeness is enforced by a model validation when a game leaves draft, not at render time.

**Tech Stack:** Ruby 3.3.12, Rails 8.0.5.1, SQLite (dev/test), PostgreSQL (production), RSpec 3.13, Cucumber 11.

## Global Constraints

- Ruby is pinned to `3.3.12` and Rails to `8.0.5.1`. Do not change either.
- rbenv is not on PATH in non-login shells. Prefix every Ruby command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never create, edit or delete any file under `features/`.** Those `.feature` files are the contract the Merb→Rails port was validated against. This includes whitespace. If a feature appears to contradict this plan, stop and report it.
- Existing gates must stay green: `bundle exec rspec` is **426 examples, 0 failures, 6 pending**; `bundle exec cucumber` is **234 scenarios, 2362 steps** (2 scenarios report "undefined" — pre-existing empty placeholders, not a regression).
- Locales are `ru` (default), `en`, `uk`, `ka` — `config.i18n.available_locales` in `config/application.rb`.
- **Platform chrome is translated via `t()`; author-written game content is rendered verbatim.** Every string this plan adds to a view is chrome and goes through `t()`. Game content never does.
- Translation keys must be added to **all four** of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb` enforces leaf-key parity across locale files and will fail the build otherwise. `uk` and `ka` may reuse the Russian string; they are largely untranslated by design.
- Object factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` (`create_game`, `create_level`, `create_hint`, `create_question`, `create_user`). Do not introduce FactoryBot.
- `spec/rails_helper.rb` enables the legacy `should` syntax alongside `expect`. **New specs use `expect`.**
- Hash rockets (`:key => value`) appear throughout older files. Match the surrounding file rather than converting it.
- Migrations use standard Rails 8 class naming (`class AddLocaleToUsers < ActiveRecord::Migration[8.0]`). Only the ported Merb-era migrations carry a `_migration` suffix; do not imitate them.
- **The `:ru` → `:en` default-locale flip is out of scope for this plan.** Do not change `config.i18n.default_locale` or `config.i18n.fallbacks`.
- Answer codes stay shared across languages. **Do not add per-locale answers.**

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/<ts>_add_locales_to_games.rb` | `primary_locale` + `available_locales` columns |
| `db/migrate/<ts>_create_content_translations.rb` | The polymorphic translation side table |
| `db/migrate/<ts>_create_game_locale_preferences.rb` | Per-user, per-game content-language override |
| `app/models/content_translation.rb` | One translated field value |
| `app/models/game_locale_preference.rb` | One player's language choice for one game |
| `app/models/concerns/translatable_content.rb` | `translated`, `translated?`, `translations_attributes=` |
| `app/controllers/concerns/content_locale_selection.rb` | Resolves a player's content locale |
| `app/views/shared/_language_tabs.html.erb` | The tab strip shared by all four authoring forms |
| `app/views/shared/_content_language_switcher.html.erb` | Player-facing per-game override control |
| `spec/support/query_counter.rb` | Counts SQL queries, for the N+1 guard |

**Modified:**

| File | Change |
|---|---|
| `app/models/game.rb` | Locale list accessors, validations, `missing_translations`, publish gate |
| `app/models/level.rb`, `hint.rb`, `question.rb` | Include the concern, define `translation_game` |
| `app/controllers/games_controller.rb` | Permit locale params, preload translations, handle the gate |
| `app/controllers/game_passings_controller.rb` | Preload translations, expose content locale |
| `app/controllers/levels_controller.rb`, `hints_controller.rb`, `questions_controller.rb` | Permit `translations` params |
| `app/views/game_passings/show_current_level.html.erb:15,26` | Render translated content + fallback notice |
| `app/views/games/_form.html.erb`, `levels/new+edit`, `hints/_form.html.erb`, `questions/new.html.erb` | Language tabs |
| `app/helpers/application_helper.rb` | `missing_translation_path_for` deep links |
| `config/locales/{ru,en,uk,ka}.yml` | New chrome keys |

---

### Task 1: Schema and the game's locale declaration

**Files:**
- Create: `db/migrate/<ts>_add_locales_to_games.rb`, `db/migrate/<ts>_create_content_translations.rb`, `db/migrate/<ts>_create_game_locale_preferences.rb`
- Modify: `app/models/game.rb`
- Test: `spec/models/game/locales_spec.rb`

**Interfaces:**
- Produces: `Game#primary_locale` (String), `Game#available_locale_list` → `Array<String>`, `Game#available_locale_list=(Array<String>)`, and the `content_translations` / `game_locale_preferences` tables. Task 2 reads `content_translations`; Task 3 calls `available_locale_list`; Task 4 reads `game_locale_preferences`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/game/locales_spec.rb
require "rails_helper"

describe Game do
  describe "locale declaration" do
    it "defaults an existing game to a single Russian locale" do
      game = create_game
      expect(game.primary_locale).to eq("ru")
      expect(game.available_locale_list).to eq(%w[ru])
    end

    it "round-trips a locale list through the comma-separated column" do
      game = create_game
      game.available_locale_list = %w[ru en ka]
      game.save!
      expect(game.reload.available_locales).to eq("ru,en,ka")
      expect(game.reload.available_locale_list).to eq(%w[ru en ka])
    end

    it "rejects a locale the platform does not know" do
      game = create_game
      game.available_locale_list = %w[ru klingon]
      expect(game).not_to be_valid
      expect(game.errors[:available_locales]).to be_present
    end

    # Without this, an author can untick their own primary language and leave a
    # game whose content the locale resolution can only reach by fallback.
    it "requires the primary locale to be among the available ones" do
      game = create_game
      game.available_locale_list = %w[en ka]
      expect(game).not_to be_valid
      expect(game.errors[:available_locales]).to be_present
    end

    it "allows the primary locale to change while the game is a draft with no translations" do
      game = create_game(:is_draft => true)
      game.available_locale_list = %w[ru en]
      game.primary_locale = "en"
      expect(game).to be_valid
    end

    # Changing it later would silently reinterpret which stored text is primary:
    # the columns would still hold Russian while the game claimed English.
    it "refuses to change the primary locale once a translation exists" do
      game = create_game(:is_draft => true)
      game.available_locale_list = %w[ru en]
      game.save!
      ContentTranslation.create!(:translatable => game, :field => "name",
                                 :locale => "en", :value => "City Quest")
      game.primary_locale = "en"
      expect(game).not_to be_valid
      expect(game.errors[:primary_locale]).to be_present
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/locales_spec.rb
```

Expected: FAIL — `undefined method 'primary_locale'`.

- [ ] **Step 3: Write the migrations**

```bash
bin/rails generate migration AddLocalesToGames
bin/rails generate migration CreateContentTranslations
bin/rails generate migration CreateGameLocalePreferences
```

Fill them in — note every column has a default, so **no existing row is updated**:

```ruby
class AddLocalesToGames < ActiveRecord::Migration[8.0]
  def change
    # Existing games were authored in Russian, so that is the honest default.
    add_column :games, :primary_locale,    :string, default: "ru", null: false
    # Comma-separated; always contains primary_locale (validated on Game).
    add_column :games, :available_locales, :string, default: "ru", null: false
  end
end
```

```ruby
class CreateContentTranslations < ActiveRecord::Migration[8.0]
  def change
    create_table :content_translations do |t|
      t.string  :translatable_type, null: false
      t.integer :translatable_id,   null: false
      t.string  :field,             null: false
      t.string  :locale,            null: false
      t.text    :value
      t.timestamps
    end
    add_index :content_translations,
              %i[translatable_type translatable_id field locale],
              unique: true, name: "index_content_translations_uniqueness"
  end
end
```

```ruby
class CreateGameLocalePreferences < ActiveRecord::Migration[8.0]
  def change
    create_table :game_locale_preferences do |t|
      t.integer :user_id, null: false
      t.integer :game_id, null: false
      t.string  :locale,  null: false
      t.timestamps
    end
    add_index :game_locale_preferences, %i[user_id game_id], unique: true
  end
end
```

- [ ] **Step 4: Run the migrations**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate && bin/rails db:test:prepare
```

Expected: three migrations applied, `db/schema.rb` updated. `spec/schema_spec.rb` compares the schema to the database — if it fails, `db:test:prepare` did not run.

- [ ] **Step 5: Add the accessors and validations to `Game`**

Add to `app/models/game.rb`, below the existing `validates` block:

```ruby
  # Stored comma-separated rather than serialised: it is a short list of ASCII
  # locale codes, it has to be readable in a SQLite console during an incident,
  # and a plain string needs no coder on either database.
  def available_locale_list
    self.available_locales.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def available_locale_list=(list)
    self.available_locales = Array(list).map(&:to_s).map(&:strip).reject(&:blank?).join(",")
  end

  def multilingual?
    self.available_locale_list.size > 1
  end

  validate :available_locales_are_known
  validate :available_locales_include_primary
  validate :primary_locale_is_settled

  private

  def available_locales_are_known
    known = I18n.available_locales.map(&:to_s)
    unknown = self.available_locale_list - known
    return if unknown.empty?

    self.errors.add(:available_locales,
                    I18n.t("activerecord.errors.models.game.attributes.available_locales.unknown",
                           :locales => unknown.join(", ")))
  end

  def available_locales_include_primary
    return if self.available_locale_list.include?(self.primary_locale.to_s)

    self.errors.add(:available_locales,
                    I18n.t("activerecord.errors.models.game.attributes.available_locales.missing_primary"))
  end

  # The columns hold the primary language's text. Repointing primary_locale
  # once translations exist would leave the columns holding one language while
  # the game claims another, and every fallback would then serve the wrong one.
  def primary_locale_is_settled
    return unless self.primary_locale_changed?
    return if self.new_record?
    return if ContentTranslation.where(:translatable => self).none? && self.draft?

    self.errors.add(:primary_locale,
                    I18n.t("activerecord.errors.models.game.attributes.primary_locale.settled"))
  end
```

Note `private` may already exist in this file — if so, add the four methods below the existing `private` keyword rather than introducing a second one.

- [ ] **Step 6: Add the chrome strings to all four locale files**

In `config/locales/ru.yml`, under `activerecord: errors: models: game: attributes:`:

```yaml
        available_locales:
          unknown: "содержит неизвестные языки: %{locales}"
          missing_primary: "должны включать основной язык игры"
        primary_locale:
          settled: "нельзя изменить после того, как добавлены переводы"
```

In `config/locales/en.yml`:

```yaml
        available_locales:
          unknown: "contains unknown languages: %{locales}"
          missing_primary: "must include the game's primary language"
        primary_locale:
          settled: "cannot be changed once translations exist"
```

Add the **same keys** to `config/locales/uk.yml` and `config/locales/ka.yml`, reusing the Russian strings as values. `spec/i18n_spec.rb` enforces leaf-key parity and will fail otherwise.

- [ ] **Step 7: Create the two new models**

```ruby
# app/models/content_translation.rb
#
# One translated field for one record. Holds NON-primary languages only: the
# primary language lives in the model's own column, which is what lets existing
# games keep working byte-identically.
class ContentTranslation < ApplicationRecord
  belongs_to :translatable, polymorphic: true

  validates :field,  presence: true
  validates :locale, presence: true
end
```

```ruby
# app/models/game_locale_preference.rb
#
# A player's per-game override of their own content language. Stored rather
# than kept in the session so a player switching device mid-race keeps it.
class GameLocalePreference < ApplicationRecord
  belongs_to :user
  belongs_to :game

  validates :locale, presence: true
end
```

- [ ] **Step 8: Run the specs**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/locales_spec.rb spec/i18n_spec.rb spec/schema_spec.rb
```

Expected: all pass.

- [ ] **Step 9: Run the full gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **432 examples** (426 + 6 new), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps.

- [ ] **Step 10: Commit**

```bash
git add db/migrate db/schema.rb app/models config/locales spec/models/game/locales_spec.rb
git commit -m "Let a game declare its primary and available locales"
```

---

### Task 2: The TranslatableContent concern

**Files:**
- Create: `app/models/concerns/translatable_content.rb`
- Modify: `app/models/game.rb`, `app/models/level.rb`, `app/models/hint.rb`, `app/models/question.rb`
- Test: `spec/models/concerns/translatable_content_spec.rb`

**Interfaces:**
- Consumes: `Game#primary_locale` and the `content_translations` table from Task 1.
- Produces: `#translated(field, locale) → String`, `#translated?(field, locale) → Boolean`, `#translations_attributes=(hash)`, and `#translation_game → Game`. Task 3 calls `translated?`; Task 5 calls `translated`; Tasks 6–7 post to `translations_attributes=`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/concerns/translatable_content_spec.rb
require "rails_helper"

describe TranslatableContent do
  let(:game) do
    g = create_game(:name => "Городской квест")
    g.available_locale_list = %w[ru en ka]
    g.save!
    g
  end
  let(:level) { create_level(:game => game, :name => "Уровень", :text => "Найдите памятник") }

  describe "#translated" do
    it "reads the model's own column for the primary locale" do
      expect(level.translated(:text, "ru")).to eq("Найдите памятник")
    end

    it "reads the side table for a non-primary locale" do
      ContentTranslation.create!(:translatable => level, :field => "text",
                                 :locale => "en", :value => "Find the monument")
      expect(level.reload.translated(:text, "en")).to eq("Find the monument")
    end

    # A blank task in the middle of a race is worse than a readable one in the
    # wrong language.
    it "falls back to the column when the locale has no translation" do
      expect(level.translated(:text, "ka")).to eq("Найдите памятник")
    end

    it "falls back when the translation row exists but is blank" do
      ContentTranslation.create!(:translatable => level, :field => "text",
                                 :locale => "ka", :value => "")
      expect(level.reload.translated(:text, "ka")).to eq("Найдите памятник")
    end
  end

  describe "#translated?" do
    it "is true for the primary locale when the column has content" do
      expect(level.translated?(:text, "ru")).to be true
    end

    # Otherwise the publish gate would pass a game whose author left a task
    # description empty in the primary language -- exactly what it exists to catch.
    it "is false for the primary locale when the column is blank" do
      level.update_column(:text, "")
      expect(level.reload.translated?(:text, "ru")).to be false
    end

    it "is false when a non-primary locale has no row" do
      expect(level.translated?(:text, "en")).to be false
    end

    it "is false when a non-primary row exists but is blank" do
      ContentTranslation.create!(:translatable => level, :field => "text",
                                 :locale => "en", :value => "  ")
      expect(level.reload.translated?(:text, "en")).to be false
    end
  end

  describe "#translations_attributes=" do
    it "creates rows for non-primary locales" do
      level.translations_attributes = { "en" => { "text" => "Find the monument",
                                                  "name" => "Level" } }
      level.save!
      expect(level.reload.translated(:text, "en")).to eq("Find the monument")
      expect(level.reload.translated(:name, "en")).to eq("Level")
    end

    it "updates an existing row rather than duplicating it" do
      level.translations_attributes = { "en" => { "text" => "First" } }
      level.save!
      level.translations_attributes = { "en" => { "text" => "Second" } }
      level.save!
      expect(level.reload.translated(:text, "en")).to eq("Second")
      expect(ContentTranslation.where(:translatable => level, :field => "text",
                                      :locale => "en").count).to eq(1)
    end

    # Writing the primary language here would put the same text in two places
    # and let them drift apart.
    it "ignores the primary locale, which belongs in the column" do
      level.translations_attributes = { "ru" => { "text" => "Другой текст" } }
      level.save!
      expect(level.reload.text).to eq("Найдите памятник")
      expect(ContentTranslation.where(:translatable => level, :locale => "ru").count).to eq(0)
    end
  end

  describe "translation_game" do
    it "resolves the owning game from every translatable model" do
      hint     = create_hint(:level => level)
      question = create_question(:level => level)
      expect(level.translation_game).to eq(game)
      expect(hint.translation_game).to eq(game)
      expect(question.translation_game).to eq(game)
      expect(game.translation_game).to eq(game)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/concerns/translatable_content_spec.rb
```

Expected: FAIL — `uninitialized constant TranslatableContent`.

- [ ] **Step 3: Write the concern**

```ruby
# app/models/concerns/translatable_content.rb
#
# Author-written game content in more than one language.
#
# The model's own column holds the game's PRIMARY language -- exactly the text
# it held before this feature existed. content_translations holds only the
# other languages. That asymmetry is deliberate: it means no existing row was
# rewritten to add multilingual support, and a game that never declares a
# second locale takes no join and no new code path.
#
# Including models must define #translation_game, returning the Game whose
# primary_locale governs them.
module TranslatableContent
  extend ActiveSupport::Concern

  # One `included` block only: ActiveSupport::Concern raises
  # MultipleIncludedBlocks if a module declares a second one.
  included do
    has_many :content_translations, :as => :translatable, :dependent => :destroy
    after_save :persist_pending_translations
  end

  # Text for `locale`, falling back to the column rather than returning nil.
  def translated(field, locale)
    return self[field] if primary_locale?(locale)

    translation_for(field, locale)&.value.presence || self[field]
  end

  # "Is there usable text for this locale", NOT "does a row exist".
  def translated?(field, locale)
    return self[field].to_s.strip.present? if primary_locale?(locale)

    translation_for(field, locale)&.value.to_s.strip.present?
  end

  # Which of `fields` have no usable text in `locale`.
  def missing_translated_fields(fields, locale)
    Array(fields).reject { |field| self.translated?(field, locale) }
  end

  # Accepts { "en" => { "text" => "...", "name" => "..." }, "ka" => { ... } }.
  # Applied on save so a validation failure does not write half the languages.
  def translations_attributes=(attributes)
    @pending_translations = attributes || {}
  end

  private

  def primary_locale?(locale)
    locale.to_s == self.translation_game&.primary_locale.to_s
  end

  # Searches the loaded association rather than querying, so a controller that
  # preloads with includes(:content_translations) pays one query for the page
  # instead of one per field. See the query-count guard in Task 5.
  def translation_for(field, locale)
    self.content_translations.detect do |translation|
      translation.field == field.to_s && translation.locale == locale.to_s
    end
  end

  def persist_pending_translations
    return if @pending_translations.blank?

    primary = self.translation_game&.primary_locale.to_s
    @pending_translations.each do |locale, fields|
      # The primary language lives in the column; storing it here too would
      # create two sources of truth that quietly diverge.
      next if locale.to_s == primary

      fields.each do |field, value|
        record = ContentTranslation.find_or_initialize_by(
          :translatable => self, :field => field.to_s, :locale => locale.to_s
        )
        record.value = value
        record.save!
      end
    end
    @pending_translations = nil
    self.content_translations.reload
  end
end
```

- [ ] **Step 4: Include it in the four models**

In `app/models/game.rb`, immediately after `class Game < ApplicationRecord`:

```ruby
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[name description].freeze

  def translation_game
    self
  end
```

In `app/models/level.rb`, after `class Level < ApplicationRecord`:

```ruby
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[name text].freeze

  def translation_game
    self.game
  end
```

In `app/models/hint.rb`, after `class Hint < ApplicationRecord`:

```ruby
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[text].freeze

  def translation_game
    self.level&.game
  end
```

In `app/models/question.rb`, after `class Question < ApplicationRecord`:

```ruby
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[questions].freeze

  def translation_game
    self.level&.game
  end
```

`questions.questions` really is the column name — the model's text field is `questions`, not `text`.

- [ ] **Step 5: Run the spec**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/concerns/translatable_content_spec.rb
```

Expected: PASS, 12 examples.

- [ ] **Step 6: Run the full gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **444 examples**, 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps. A cucumber regression here would mean `after_save` broke an existing write path — investigate rather than adjusting the feature.

- [ ] **Step 7: Commit**

```bash
git add app/models spec/models/concerns/translatable_content_spec.rb
git commit -m "Add TranslatableContent: column for the primary language, side table for the rest"
```

---

### Task 3: The publish gate

**Files:**
- Modify: `app/models/game.rb`
- Test: `spec/models/game/missing_translations_spec.rb`

**Interfaces:**
- Consumes: `#translated?` and `TRANSLATABLE_FIELDS` from Task 2, `#available_locale_list` from Task 1.
- Produces: `Game#missing_translations → Array<Game::MissingTranslation>` where `MissingTranslation` is a `Struct` with members `:record`, `:field`, `:locale`, `:label`. Task 8 renders these as deep links.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/models/game/missing_translations_spec.rb
require "rails_helper"

describe Game do
  let(:game) do
    g = create_game(:is_draft => true, :name => "Квест", :description => "Описание")
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  describe "#missing_translations" do
    it "is empty for a single-locale game" do
      single = create_game(:is_draft => true)
      create_level(:game => single)
      expect(single.missing_translations).to eq([])
    end

    it "reports the game's own untranslated fields" do
      missing = game.missing_translations
      expect(missing.map(&:field)).to include("name", "description")
      expect(missing.map(&:locale).uniq).to eq(%w[en])
    end

    it "reports untranslated level, hint and question fields" do
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      create_hint(:level => level, :text => "Подсказка")
      create_question(:level => level)

      records = game.missing_translations.map(&:record)
      expect(records).to include(level)
      expect(records.map(&:class).uniq).to include(Level, Hint, Question)
    end

    it "stops reporting a field once it is translated" do
      game.translations_attributes = { "en" => { "name" => "Quest",
                                                 "description" => "Description" } }
      game.save!
      expect(game.reload.missing_translations.map(&:field)).not_to include("name")
    end

    it "carries a human label so the author can find the field" do
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      entry = game.missing_translations.detect { |m| m.record == level && m.field == "text" }
      expect(entry.label).to be_present
    end
  end

  describe "the publish gate" do
    it "lets a complete game leave draft" do
      complete = create_game(:is_draft => true)
      create_level(:game => complete)
      complete.is_draft = false
      expect(complete).to be_valid
    end

    # This is a race: a team reaching a level it cannot read loses the leg.
    it "refuses to leave draft while a declared locale is incomplete" do
      create_level(:game => game, :name => "Уровень", :text => "Текст")
      game.is_draft = false
      expect(game).not_to be_valid
      expect(game.errors[:base]).to be_present
    end

    it "still allows a draft game to be saved while incomplete" do
      create_level(:game => game, :name => "Уровень", :text => "Текст")
      expect(game).to be_valid
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/missing_translations_spec.rb
```

Expected: FAIL — `undefined method 'missing_translations'`.

- [ ] **Step 3: Implement it in `Game`**

Add near the top of `app/models/game.rb`, after `include TranslatableContent`:

```ruby
  # Not a boolean: these entries are simultaneously the publish gate's reason
  # for refusing and the author's to-do list, so they carry enough to render a
  # deep link straight to the offending field.
  MissingTranslation = Struct.new(:record, :field, :locale, :label)
```

and, with the other public methods:

```ruby
  def missing_translations
    non_primary = self.available_locale_list - [self.primary_locale.to_s]
    return [] if non_primary.empty?

    non_primary.flat_map do |locale|
      translatable_records.flat_map do |record|
        record.class::TRANSLATABLE_FIELDS.map do |field|
          next if record.translated?(field, locale)

          MissingTranslation.new(record, field, locale, label_for(record, field))
        end.compact
      end
    end
  end

  def translations_complete?
    self.missing_translations.empty?
  end
```

and in the private section:

```ruby
  def translatable_records
    records = [ self ]
    # Nested, not sibling: includes(:hints, :questions, :content_translations)
    # preloads the LEVEL's translations but leaves each hint and question to
    # lazy-load its own, which is one query per record.
    self.levels.includes(:content_translations,
                         :hints => :content_translations,
                         :questions => :content_translations).each do |level|
      records << level
      records.concat(level.hints)
      records.concat(level.questions)
    end
    records
  end

  def label_for(record, field)
    case record
    when Game     then I18n.t("games.translations.game_field",  :field => field)
    when Level    then I18n.t("games.translations.level_field", :position => record.position, :field => field)
    when Hint     then I18n.t("games.translations.hint_field",  :position => record.level&.position,
                                                                :minutes => record.delay_in_minutes)
    when Question then I18n.t("games.translations.question_field", :position => record.level&.position)
    end
  end
```

Then the gate itself, with the other validations:

```ruby
  validate :declared_locales_are_translated_before_publication

  # ...in the private section:

  # Fires whenever the game is not a draft, not merely on the draft -> published
  # edge. is_draft_changed?(:from => true, :to => false) misses the two paths
  # that matter: a game created directly with is_draft false (the new-game form
  # leaves the checkbox unchecked and the column defaults to false), and a
  # locale added to an already-published game, where is_draft never changes.
  # Both would otherwise put a game teams cannot fully read into play.
  #
  # Single-locale games short-circuit inside missing_translations, so this
  # costs nothing for the overwhelmingly common case. An author may still save
  # an incomplete DRAFT and finish the translation over several sittings.
  def declared_locales_are_translated_before_publication
    return if self.draft?

    missing = self.missing_translations
    return if missing.empty?

    self.errors.add(:base, I18n.t("games.translations.incomplete", :count => missing.size))
  end
```

- [ ] **Step 4: Add the chrome strings to all four locale files**

`config/locales/ru.yml`, under `games:`:

```yaml
    translations:
      incomplete: "Игра объявляет языки, на которые переведено не всё: не хватает %{count} полей"
      game_field: "Игра — %{field}"
      level_field: "Уровень %{position} — %{field}"
      hint_field: "Уровень %{position} — подсказка через %{minutes} мин"
      question_field: "Уровень %{position} — вопрос"
```

`config/locales/en.yml`:

```yaml
    translations:
      incomplete: "This game declares languages it is not fully translated into: %{count} fields are missing"
      game_field: "Game — %{field}"
      level_field: "Level %{position} — %{field}"
      hint_field: "Level %{position} — hint after %{minutes} min"
      question_field: "Level %{position} — question"
```

Add the same keys to `uk.yml` and `ka.yml` with the Russian values.

- [ ] **Step 5: Run the specs**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/missing_translations_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 8 + i18n examples.

- [ ] **Step 6: Run the full gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **452 examples**, 0 failures, 6 pending; cucumber unchanged. Cucumber exercises publishing single-locale games heavily — the `return [] if non_primary.empty?` short-circuit is what keeps those green.

- [ ] **Step 7: Commit**

```bash
git add app/models/game.rb config/locales spec/models/game/missing_translations_spec.rb
git commit -m "Block publication while a declared locale is incompletely translated"
```

---

### Task 4: Resolving a player's content locale

**Files:**
- Create: `app/controllers/concerns/content_locale_selection.rb`
- Modify: `app/controllers/application_controller.rb`
- Test: `spec/requests/content_locale_spec.rb`

**Interfaces:**
- Consumes: `Game#available_locale_list`, `Game#primary_locale`, `GameLocalePreference` from Task 1.
- Produces: `#content_locale_for(game) → String`, available in controllers and views (declared `helper_method`). Task 5 calls it when rendering.

- [ ] **Step 1: Write the failing request spec**

```ruby
# spec/requests/content_locale_spec.rb
require "rails_helper"

describe "content locale resolution", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  it "uses the game's primary locale for an anonymous visitor" do
    expect(controller_content_locale_for(game)).to eq("ru")
  end

  it "uses the user's own locale when the game offers it" do
    user = create_user
    user.update!(:locale => "en")
    expect(controller_content_locale_for(game, :user => user)).to eq("en")
  end

  # A Georgian speaker browsing a Russian-only game reads Russian content
  # inside Georgian chrome. The two locales are independent by design.
  it "falls through to the primary locale when the game does not offer the user's" do
    user = create_user
    user.update!(:locale => "ka")
    expect(controller_content_locale_for(game, :user => user)).to eq("ru")
  end

  it "prefers a stored per-game override over the user's locale" do
    user = create_user
    user.update!(:locale => "ru")
    GameLocalePreference.create!(:user => user, :game => game, :locale => "en")
    expect(controller_content_locale_for(game, :user => user)).to eq("en")
  end

  it "ignores an override for a locale the game no longer offers" do
    user = create_user
    user.update!(:locale => "ru")
    GameLocalePreference.create!(:user => user, :game => game, :locale => "ka")
    expect(controller_content_locale_for(game, :user => user)).to eq("ru")
  end

  # A real request runs LocaleSelection#set_locale first, which resolves the
  # user's stored preference (or ?locale=) into I18n.locale and wraps the action
  # in I18n.with_locale. This harness reproduces that, rather than testing a
  # path no request takes.
  def controller_content_locale_for(game, user: nil)
    controller = ApplicationController.new
    controller.define_singleton_method(:current_user) { user }
    chrome_locale = user&.locale.presence || I18n.default_locale
    I18n.with_locale(chrome_locale) { controller.send(:content_locale_for, game) }
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/content_locale_spec.rb
```

Expected: FAIL — `undefined method 'content_locale_for'`.

- [ ] **Step 3: Write the concern**

```ruby
# app/controllers/concerns/content_locale_selection.rb
#
# Which language a player reads a given game's CONTENT in.
#
# Deliberately separate from LocaleSelection, which picks the platform chrome
# locale. The two are independent: a Georgian speaker browsing a Russian-only
# game gets Georgian menus and Russian tasks, because that is the best
# available answer rather than a compromise between them.
module ContentLocaleSelection
  extend ActiveSupport::Concern

  included do
    helper_method :content_locale_for
  end

  private

  # Precedence: the player's explicit per-game choice, then their own locale
  # (which LocaleSelection has already resolved from ?locale= or their
  # profile), then the game's primary language.
  def content_locale_for(game)
    return nil if game.nil?

    @content_locales ||= {}
    # Keyed on the game, not game.id: an unpersisted Game has a nil id, so two
    # different unsaved games would share one cache entry.
    @content_locales[game] ||= begin
      offered = game.available_locale_list
      candidate = per_game_content_locale(game) || current_content_user_locale
      offered.include?(candidate.to_s) ? candidate.to_s : game.primary_locale.to_s
    end
  end

  def per_game_content_locale(game)
    return nil unless respond_to?(:current_user, true) && current_user

    GameLocalePreference.find_by(:user_id => current_user.id, :game_id => game.id)&.locale
  end

  # LocaleSelection has already resolved ?locale= -> the user's stored
  # preference -> the instance default into I18n.locale, and wrapped the action
  # in I18n.with_locale. Reading current_user.locale directly here would
  # reimplement half of that and honour ?locale= for anonymous visitors only,
  # so an organiser previewing with ?locale=en would get English chrome and
  # Russian tasks while a signed-out visitor got English both.
  def current_content_user_locale
    I18n.locale.to_s
  end
end
```

- [ ] **Step 4: Include it in `ApplicationController`**

In `app/controllers/application_controller.rb`, beside the existing `include LocaleSelection`:

```ruby
  include ContentLocaleSelection
```

- [ ] **Step 5: Run the spec**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/content_locale_spec.rb
```

Expected: PASS, 5 examples.

- [ ] **Step 6: Run the full gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **457 examples**, 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 7: Commit**

```bash
git add app/controllers spec/requests/content_locale_spec.rb
git commit -m "Resolve a player's content locale independently of chrome locale"
```

---

### Task 5: Rendering translated content to players, without an N+1

**Files:**
- Create: `spec/support/query_counter.rb`, `app/views/shared/_content_language_switcher.html.erb`
- Modify: `app/views/game_passings/show_current_level.html.erb`, `app/controllers/game_passings_controller.rb`, `config/routes.rb`
- Test: `spec/requests/translated_level_spec.rb`

**Interfaces:**
- Consumes: `#translated`, `#missing_translated_fields` (Task 2), `#content_locale_for` (Task 4).
- Produces: `POST /play/:game_id/content_locale` (named `set_content_locale`) storing a `GameLocalePreference`.

- [ ] **Step 1: Write the query counter**

```ruby
# spec/support/query_counter.rb
#
# The N+1 in this feature is invisible in development -- three hints and a
# question look fine -- and expensive in a live game with a full field of
# teams. This makes a forgotten `includes` fail the build instead.
module QueryCounter
  def count_queries(&block)
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      count += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end

RSpec.configure { |config| config.include QueryCounter }
```

Require it from `spec/rails_helper.rb` by adding, next to the other requires:

```ruby
require_relative "support/query_counter"
```

- [ ] **Step 2: Write the failing request spec**

```ruby
# spec/requests/translated_level_spec.rb
require "rails_helper"

describe "playing a translated game", type: :request do
  let(:game) do
    g = create_game(:is_draft => false)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end
  let(:level) { create_level(:game => game, :name => "Уровень", :text => "Найдите памятник") }

  before do
    level
    level.translations_attributes = { "en" => { "text" => "Find the monument",
                                                "name" => "Level" } }
    level.save!
    3.times { |i| create_hint(:level => level, :text => "Подсказка #{i}") }
  end

  it "renders the level in the player's language" do
    expect(level.reload.translated(:text, "en")).to eq("Find the monument")
    expect(level.reload.translated(:text, "ru")).to eq("Найдите памятник")
  end

  # Guards the specific mistake this design invites: forgetting to preload, so
  # each hint and question issues its own translation query.
  it "does not issue a query per translated record" do
    level.reload
    baseline = count_queries do
      Level.includes(:hints, :questions, :content_translations).find(level.id).tap do |l|
        l.translated(:text, "en")
        l.hints.each { |h| h.translated(:text, "en") }
        l.questions.each { |q| q.translated(:questions, "en") }
      end
    end

    expect(baseline).to be <= 5
  end
end
```

- [ ] **Step 3: Run it to verify the counter works**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/translated_level_spec.rb
```

Expected: PASS on the first example. If the second fails with a count above 5, the concern is querying rather than searching the loaded association — fix `translation_for` before continuing.

- [ ] **Step 4: Preload in the controller**

In `app/controllers/game_passings_controller.rb`, find where the current level is loaded for `show_current_level` and preload the associations. Add this method and call it in place of the bare level lookup:

```ruby
  # translated() searches the loaded association rather than querying, so this
  # preload is what makes it O(1) per page instead of O(fields).
  def preloaded_level(level)
    Level.includes(:hints, :questions, :content_translations).find(level.id)
  end
```

- [ ] **Step 5: Render translated content**

Replace `app/views/game_passings/show_current_level.html.erb:15`:

```erb
  <%= @game_passing.current_level.text %>
```

with:

```erb
  <%= @game_passing.current_level.translated(:text, content_locale_for(@game_passing.game)) %>
```

and line 26:

```erb
      <%= hint.text %>
```

with:

```erb
      <%= hint.translated(:text, content_locale_for(@game_passing.game)) %>
```

Then add the fallback notice near the top of the level block. Because publication is blocked on completeness, this can only fire for content added after the game started — one notice per page, not one per field:

```erb
<% content_locale = content_locale_for(@game_passing.game) %>
<% if @game_passing.current_level.missing_translated_fields(Level::TRANSLATABLE_FIELDS, content_locale).any? %>
  <p class="notice"><%= t("game_passings.content_not_translated") %></p>
<% end %>
```

- [ ] **Step 6: Add the switcher and its route**

```erb
<%# app/views/shared/_content_language_switcher.html.erb %>
<%# Only worth showing when there is actually a choice to make. %>
<% if game.multilingual? %>
  <div class="content-language-switcher">
    <%= t("game_passings.content_language") %>:
    <% game.available_locale_list.each do |locale| %>
      <%= button_to t("locale_name.#{locale}"),
                    set_content_locale_path(:game_id => game.id, :locale => locale),
                    :method => :post, :class => "language-choice" %>
    <% end %>
  </div>
<% end %>
```

In `config/routes.rb`, beside the other `/play` routes:

```ruby
  post "/play/:game_id/content_locale", to: "game_passings#set_content_locale", as: :set_content_locale
```

In `app/controllers/game_passings_controller.rb`:

```ruby
  def set_content_locale
    game = Game.find(params[:game_id])
    if game.available_locale_list.include?(params[:locale].to_s)
      preference = GameLocalePreference.find_or_initialize_by(:user_id => current_user.id,
                                                             :game_id => game.id)
      preference.locale = params[:locale].to_s
      preference.save!
    end
    redirect_to show_current_level_path(:game_id => game.id)
  end
```

- [ ] **Step 7: Add the chrome strings to all four locale files**

`config/locales/ru.yml`, under `game_passings:`:

```yaml
    content_not_translated: "Это задание пока не переведено на ваш язык — показан язык оригинала."
    content_language: "Язык заданий"
```

`config/locales/en.yml`:

```yaml
    content_not_translated: "This task is not translated into your language yet — showing the original."
    content_language: "Task language"
```

Same keys in `uk.yml` and `ka.yml` with the Russian values. `locale_name.*` keys already exist — the language switcher added during the port uses them.

- [ ] **Step 8: Run the full gates**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec && bundle exec cucumber
```

Expected: **459 examples**, 0 failures, 6 pending; cucumber unchanged at 234 scenarios. Cucumber drives `show_current_level` extensively in Russian single-locale games — if it regresses, `translated` is not returning the column for the primary locale.

- [ ] **Step 9: Commit**

```bash
git add spec/support app/views app/controllers config/routes.rb config/locales spec/requests/translated_level_spec.rb spec/rails_helper.rb
git commit -m "Render level content in the player's language, with an N+1 guard"
```

---

### Task 6: Language tabs on the game and level forms

**Files:**
- Create: `app/views/shared/_language_tabs.html.erb`
- Modify: `app/views/games/_form.html.erb`, `app/views/levels/new.html.erb`, `app/views/levels/edit.html.erb`, `app/controllers/games_controller.rb`, `app/controllers/levels_controller.rb`
- Test: `spec/requests/authoring_translations_spec.rb`

**Interfaces:**
- Consumes: `#translations_attributes=` (Task 2), `Game#available_locale_list` (Task 1).
- Produces: forms posting `level[translations][<locale>][<field>]`, and the `_language_tabs` partial reused by Task 7.

- [ ] **Step 1: Write the failing request spec**

```ruby
# spec/requests/authoring_translations_spec.rb
require "rails_helper"

describe "authoring translations", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  it "saves a level translation submitted from the English tab" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
    level.save!

    expect(level.reload.translated(:name, "en")).to eq("Level")
    expect(level.reload.translated(:text, "en")).to eq("Text")
    expect(level.reload.name).to eq("Уровень")
  end

  it "saves a game translation without touching the primary columns" do
    game.translations_attributes = { "en" => { "name" => "City Quest",
                                               "description" => "A quest" } }
    game.save!

    expect(game.reload.translated(:name, "en")).to eq("City Quest")
    expect(game.reload.name).not_to eq("City Quest")
  end
end
```

- [ ] **Step 2: Run it to verify it passes at the model level**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/authoring_translations_spec.rb
```

Expected: PASS — this pins the contract the forms must post against before the forms exist.

- [ ] **Step 3: Write the tab strip partial**

```erb
<%# app/views/shared/_language_tabs.html.erb

    Locals:
      game    - the Game whose available_locale_list drives the tabs
      record  - the record being edited (for the per-tab missing count)
      fields  - the field names this form edits, e.g. Level::TRANSLATABLE_FIELDS
      active  - the currently selected locale

    Renders nothing for a single-locale game, so monolingual authors see the
    form exactly as it was before this feature existed.
%>
<% if game.multilingual? %>
  <ul class="language-tabs">
    <% game.available_locale_list.each do |locale| %>
      <% missing = record.new_record? ? [] : record.missing_translated_fields(fields, locale) %>
      <li class="<%= "active" if locale == active %> <%= "incomplete" if missing.any? %>">
        <%= link_to url_for(request.query_parameters.merge(:tab => locale)) do %>
          <%= t("locale_name.#{locale}") %>
          <% if missing.any? %>
            <span class="missing-count"><%= t("games.translations.missing_count", :count => missing.size) %></span>
          <% end %>
        <% end %>
      </li>
    <% end %>
  </ul>
<% end %>
```

- [ ] **Step 4: Wire the tabs into the level form**

In both `app/views/levels/new.html.erb` and `app/views/levels/edit.html.erb`, above the form fields:

```erb
<% active_locale = params[:tab].presence_in(@game.available_locale_list) || @game.primary_locale %>
<%= render "shared/language_tabs", :game => @game, :record => @level,
                                   :fields => Level::TRANSLATABLE_FIELDS,
                                   :active => active_locale %>
```

Then make the name and text inputs write to the column when the active tab is the primary locale, and to the translation hash otherwise:

```erb
<% if active_locale == @game.primary_locale %>
  <%= f.text_field :name %>
  <%= f.text_area  :text %>
<% else %>
  <%= text_field_tag "level[translations][#{active_locale}][name]",
                     @level.translated(:name, active_locale) %>
  <%= text_area_tag  "level[translations][#{active_locale}][text]",
                     @level.translated(:text, active_locale) %>
<% end %>
```

Keep whatever labels and wrapper markup the existing form uses around these inputs — this step replaces the inputs, not the layout.

- [ ] **Step 5: Permit the parameters**

In `app/controllers/levels_controller.rb`, extend the permitted params. A nested hash of unknown locale keys needs an explicit permit:

```ruby
  def level_params
    params.require(:level)
          .permit(:name, :text, :position,
                  :translations => translation_params_shape(Level::TRANSLATABLE_FIELDS))
  end

  # params.permit cannot express "any locale key", so build the shape from the
  # locales this platform actually knows.
  def translation_params_shape(fields)
    I18n.available_locales.map(&:to_s).index_with { fields.map(&:to_sym) }
  end
```

Then rename the incoming key so it reaches the writer:

```ruby
  # translations_attributes= is the concern's writer; the form posts
  # `translations` because that is what reads naturally in the markup.
  def level_attributes
    attributes = level_params.to_h
    translations = attributes.delete("translations")
    attributes.merge("translations_attributes" => translations)
  end
```

Use `level_attributes` where the controller currently uses `level_params` in `create` and `update`.

- [ ] **Step 6: Do the same for the game form**

In `app/views/games/_form.html.erb`, add the tab strip with `:record => @game` and `:fields => Game::TRANSLATABLE_FIELDS`, and the same conditional inputs for `name` and `description`. In `app/controllers/games_controller.rb`, add `:primary_locale`, `:available_locale_list => []` and the `:translations` shape to `game_params`, and add the same `translations` → `translations_attributes` rename.

- [ ] **Step 7: Add the chrome string to all four locale files**

`config/locales/ru.yml` under `games: translations:`:

```yaml
      missing_count: "не хватает: %{count}"
```

`config/locales/en.yml`:

```yaml
      missing_count: "%{count} missing"
```

Same key in `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 8: Run the full gates**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec && bundle exec cucumber
```

Expected: **461 examples**, 0 failures, 6 pending; cucumber unchanged at 234 scenarios. Cucumber fills these forms in Russian throughout — the `if game.multilingual?` guard and the primary-locale branch are what keep those scenarios untouched.

- [ ] **Step 9: Commit**

```bash
git add app/views app/controllers config/locales spec/requests/authoring_translations_spec.rb
git commit -m "Add language tabs to the game and level forms"
```

---

### Task 7: Language tabs on the hint and question forms

**Files:**
- Modify: `app/views/hints/_form.html.erb`, `app/views/questions/new.html.erb`, `app/controllers/hints_controller.rb`, `app/controllers/questions_controller.rb`
- Test: `spec/requests/authoring_translations_spec.rb` (extend)

**Interfaces:**
- Consumes: `shared/_language_tabs` (Task 6), `#translations_attributes=` (Task 2).

- [ ] **Step 1: Extend the spec**

Append to `spec/requests/authoring_translations_spec.rb`, inside the existing `describe` block:

```ruby
  it "saves a hint translation" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    hint = create_hint(:level => level, :text => "Подсказка")
    hint.translations_attributes = { "en" => { "text" => "Hint" } }
    hint.save!

    expect(hint.reload.translated(:text, "en")).to eq("Hint")
    expect(hint.reload.text).to eq("Подсказка")
  end

  it "saves a question translation" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    question = create_question(:level => level)
    question.translations_attributes = { "en" => { "questions" => "What colour is the door?" } }
    question.save!

    expect(question.reload.translated(:questions, "en")).to eq("What colour is the door?")
  end
```

- [ ] **Step 2: Run it**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/authoring_translations_spec.rb
```

Expected: PASS, 4 examples.

- [ ] **Step 3: Add tabs to the hint form**

In `app/views/hints/_form.html.erb`, above the fields:

```erb
<% active_locale = params[:tab].presence_in(@level.game.available_locale_list) || @level.game.primary_locale %>
<%= render "shared/language_tabs", :game => @level.game, :record => @hint,
                                   :fields => Hint::TRANSLATABLE_FIELDS,
                                   :active => active_locale %>
```

and branch the text input:

```erb
<% if active_locale == @level.game.primary_locale %>
  <%= f.text_field :text %>
<% else %>
  <%= text_field_tag "hint[translations][#{active_locale}][text]",
                     @hint.translated(:text, active_locale) %>
<% end %>
```

The `delay_in_minutes` field is **not** translatable — a hint fires at the same moment in every language. Leave it outside the branch.

- [ ] **Step 4: Add tabs to the question form**

In `app/views/questions/new.html.erb`, the same pattern with `Question::TRANSLATABLE_FIELDS` and the field name `questions`. The answers field is **not** branched: answer codes are shared across languages by design.

Add help text beside the answers input, since nothing else tells an author this:

```erb
<p class="hint-text"><%= t("questions.answers_are_shared") %></p>
```

- [ ] **Step 5: Permit the parameters in both controllers**

In `app/controllers/hints_controller.rb` and `app/controllers/questions_controller.rb`, add the same permitted-shape helper and `translations` → `translations_attributes` rename used in Task 6 Step 5, with that controller's own `TRANSLATABLE_FIELDS`.

- [ ] **Step 6: Add the chrome string to all four locale files**

`config/locales/ru.yml` under `questions:`:

```yaml
    answers_are_shared: "Коды ответов общие для всех языков. Если ответ пишется по-разному, добавьте каждый вариант как отдельный правильный ответ."
```

`config/locales/en.yml`:

```yaml
    answers_are_shared: "Answer codes are shared across languages. If the answer is written differently in each, add every spelling as a separate correct answer."
```

Same key in `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 7: Run the full gates**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec && bundle exec cucumber
```

Expected: **463 examples**, 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 8: Commit**

```bash
git add app/views app/controllers config/locales spec/requests/authoring_translations_spec.rb
git commit -m "Add language tabs to the hint and question forms"
```

---

### Task 8: Showing the author what is missing

**Files:**
- Create: `app/views/games/_missing_translations.html.erb`
- Modify: `app/controllers/games_controller.rb`, `app/views/games/show.html.erb`
- Test: `spec/requests/publish_gate_spec.rb`

**Interfaces:**
- Consumes: `Game#missing_translations` and `Game::MissingTranslation` (Task 3).

- [ ] **Step 1: Write the failing request spec**

```ruby
# spec/requests/publish_gate_spec.rb
require "rails_helper"

describe "the publish gate", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  it "lists every missing field with a locale and a label" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    create_hint(:level => level, :text => "Подсказка")

    entries = game.missing_translations
    expect(entries).to be_present
    entries.each do |entry|
      expect(entry.locale).to eq("en")
      expect(entry.label).to be_present
      expect(entry.field).to be_present
      expect(entry.record).to be_present
    end
  end

  it "refuses publication and explains why" do
    create_level(:game => game, :name => "Уровень", :text => "Текст")
    game.is_draft = false
    expect(game.save).to be false
    expect(game.errors[:base].join).to be_present
  end

  it "permits publication once every declared locale is complete" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    game.translations_attributes = { "en" => { "name" => "Quest", "description" => "Desc" } }
    game.save!
    level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
    level.save!

    game.reload.is_draft = false
    expect(game.save).to be true
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/publish_gate_spec.rb
```

Expected: the first two pass (Task 3 built them); the third fails if `translations_attributes=` is not reloading the association before the gate re-checks.

- [ ] **Step 3: Write the missing-translations partial**

```erb
<%# app/views/games/_missing_translations.html.erb

    This is the compensation for choosing language tabs over a whole-game
    translation matrix: tabs show gaps one level at a time, which alone would
    make an author with fourteen levels click through fourteen forms to find
    out what is missing. The gate generates the list instead, at the only
    moment it matters.
%>
<% entries = game.missing_translations %>
<% if entries.any? %>
  <div class="missing-translations">
    <h3><%= t("games.translations.heading", :count => entries.size) %></h3>
    <ul>
      <% entries.each do |entry| %>
        <li>
          <%= link_to "#{entry.label} — #{t("locale_name.#{entry.locale}")}",
                      missing_translation_path_for(entry) %>
        </li>
      <% end %>
    </ul>
  </div>
<% end %>
```

- [ ] **Step 4: Add the deep-link helper**

In `app/helpers/application_helper.rb`:

```ruby
  # Each link opens the right form on the right language tab, so the author
  # goes from "what is missing" to "fixing it" in one click.
  def missing_translation_path_for(entry)
    case entry.record
    when Game     then edit_game_path(entry.record, :tab => entry.locale)
    when Level    then edit_game_level_path(entry.record.game, entry.record, :tab => entry.locale)
    when Hint     then edit_game_level_hint_path(entry.record.level.game, entry.record.level,
                                                 entry.record, :tab => entry.locale)
    when Question then new_game_level_question_path(entry.record.level.game, entry.record.level,
                                                    :locale => entry.locale)
    end
  end
```

These four helper names were verified against `bin/rails routes` while this plan was written: `edit_game`, `edit_game_level`, `edit_game_level_hint` and `new_game_level_question` all exist. `Question` uses `new_…` rather than `edit_…` because questions are created and edited through the same form.

- [ ] **Step 5: Render it on the game page**

In `app/views/games/show.html.erb`, inside the author-only section:

```erb
<% if @game.draft? && @game.author == current_user %>
  <%= render "games/missing_translations", :game => @game %>
<% end %>
```

- [ ] **Step 6: Add the chrome string to all four locale files**

`config/locales/ru.yml` under `games: translations:`:

```yaml
      heading: "Не переведено (%{count})"
```

`config/locales/en.yml`:

```yaml
      heading: "Not translated yet (%{count})"
```

Same key in `uk.yml` and `ka.yml` with the Russian value.

- [ ] **Step 7: Run the full gates**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec && bundle exec cucumber
```

Expected: **466 examples**, 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps.

- [ ] **Step 8: Run the autoloading check**

```bash
bin/rails zeitwerk:check
```

Expected: `All is good!` — this catches a concern or model placed where Zeitwerk cannot find it.

- [ ] **Step 9: Commit**

```bash
git add app/views app/helpers config/locales spec/requests/publish_gate_spec.rb
git commit -m "Show the author exactly which fields block publication"
```

---

## Self-Review

**Spec coverage.** Locale declaration and the `available_locales ⊇ {primary_locale}` invariant (Task 1); `content_translations` and `game_locale_preferences` tables (Task 1); the `TranslatableContent` concern with column-for-primary, fallback-to-column, and `translated?` treating blank as absent (Task 2); `missing_translations` as structured entries plus the draft→published gate (Task 3); the three-step locale precedence (Task 4); player-facing rendering, the single-per-page fallback notice, the per-game override, and the N+1 query-count guard (Task 5); language tabs on all four authoring forms (Tasks 6–7); the enumerated missing-translation list with deep links (Task 8); shared answer codes with author help text (Task 7 Step 4). `primary_locale` immutability is Task 1 Step 5. Non-destructive locale removal needs no code — nothing deletes `content_translations` rows when a locale is untucked, which the `dependent: :destroy` on the *record* association does not affect.

**Explicitly out of scope, per the spec:** the `:ru` → `:en` default flip and the `config.i18n.fallbacks` change. No task touches them.

**Placeholder scan.** No "TBD" or "add validation". Two steps deliberately say "match the existing markup" rather than reproducing view layout — Task 6 Step 4 and Task 7 Step 3 — because the surrounding labels and wrappers differ per form and reproducing them here would invite an implementer to overwrite working markup. Task 8 Step 4 tells the implementer to verify route helper names with `bin/rails routes` rather than trusting names this plan guessed at.

**Type consistency.** `available_locale_list` (not `available_locales_list` or `locales`) is used in Tasks 1, 3, 4, 5, 6. `TRANSLATABLE_FIELDS` is a constant on each of the four models, referenced in Tasks 3, 5, 6, 7. `MissingTranslation` members are `:record, :field, :locale, :label`, used identically in Tasks 3 and 8. `translations_attributes=` is the writer everywhere; forms post `translations` and controllers rename it, stated in Tasks 6 and 7. `content_locale_for(game)` returns a `String` in Tasks 4 and 5.

**Running example counts.** 426 → 432 (T1) → 444 (T2) → 452 (T3) → 457 (T4) → 459 (T5) → 461 (T6) → 463 (T7) → 466 (T8). Cucumber stays at 234 scenarios / 2362 steps throughout; any change there is a regression, not a new feature.
