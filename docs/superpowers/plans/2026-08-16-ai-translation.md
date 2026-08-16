# AI Translation of Game Content — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Suite discipline for this repository:** a subagent runs only the *targeted* spec files named in its task. The full `bundle exec rspec` and `bundle exec cucumber` gates are run by the orchestrator, never delegated — backgrounded full-suite runs have stalled subagents repeatedly here.

**Goal:** Let a superadmin translate a game's author-written content into any registered locale via the Claude API, review what the model produced, and accept it — after which the stored translation is byte-identical to one typed by hand.

**Architecture:** A `TranslationRun` row plus a background `Thread` walks the game's missing translatable fields, calls Claude once per level subtree with the source content sitting inside a cached prompt prefix, and writes `TranslationProposal` rows. A superadmin reviews proposals — mechanically flagged for structural failures — and accepting one writes a `ContentTranslation` through the same setter the authoring form uses. No new ActiveJob backend, no JavaScript.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, sqlite (dev/test) / Postgres (prod), RSpec, `anthropic` gem, Claude Messages API with structured outputs and prompt caching.

**Spec:** `docs/superpowers/specs/2026-08-16-ai-translation-design.md` — read it alongside this plan; every task argues from it.

**Worktree:** `/home/mezinster/encounter-engine-ai-translation`, branch `feature/ai-translation` (off `master`). All paths below are relative to that directory.

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Every command below assumes you have first run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any `features/**/*.feature` file.** The inherited contract is 228 scenarios / 2325 steps and must not move. This plan adds no feature file at all.
- **Hash rockets** (`:key => value`), including for symbol keys. Match the surrounding file.
- **Code, identifiers and comments in English; user-facing strings in Russian via `t()`.**
- **Seven locales, all of them, every time:** `ru en uk ka tr be pl`. `config/locales/*.yml`. The test environment sets `raise_on_missing_translations`, so a missing key is a red build.
- **`ru` is the default locale**; `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and subset-of-`ru` for the other five.
- **A validation message is a predicate, not a sentence.** Every new validator needs *both* an `activerecord.attributes.<model>.<attr>` noun and an `activerecord.errors.models.<model>...` predicate, and in ru/uk/be/pl the predicate must agree in gender with its own noun.
- **`create_user` takes no arguments.** Factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb`, not FactoryBot.
- **Model IDs are exact strings, never date-suffixed:** `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5`.
- **`Answer` must never acquire translatable fields.**

---

## Task 0: Worktree setup

**Files:** none created — environment only.

- [ ] **Step 1: Install dependencies and create the test database**

```bash
cd /home/mezinster/encounter-engine-ai-translation
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle install
bin/rails db:test:prepare
```

The worktree has its own empty `db/` — neither sqlite file is in the repository, and `db:test:prepare` creates `db/test.sqlite3` from `db/schema.rb`.

- [ ] **Step 2: Confirm a green baseline before changing anything**

```bash
bundle exec rspec 2>&1 | tail -5
bundle exec cucumber 2>&1 | tail -5
```

Expected: RSpec `0 failures`. **Write both counts into the ledger** — they are the only trustworthy baseline. Do not compare against any figure quoted in `CLAUDE.md` or in this plan's Task 10; both have been stale before, which is the documented reason this step exists.

---

## Task 1: Schema and models for runs and proposals

**Files:**
- Create: `db/migrate/20260816100000_create_translation_runs.rb`
- Create: `app/models/translation_run.rb`
- Create: `app/models/translation_proposal.rb`
- Test: `spec/models/translation_run_spec.rb`
- Test: `spec/models/translation_proposal_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `TranslationRun` with `#target_locale_list` → `Array<String>`, `#target_locale_list=(Array)`, `#running?`, `#terminal?`, `#progress_fraction` → `Float`, and scope `TranslationRun.active_for(game)` → relation.
  - `TranslationProposal` with `#flag_list` → `Array<String>`, `#flag_list=(Array)`, `#flagged?` → Boolean, scopes `.pending`, `.unflagged`.
  - States as string constants: run `pending|running|succeeded|failed|cancelled`; proposal `pending|accepted|rejected`.

- [ ] **Step 1: Write the failing model specs**

Create `spec/models/translation_run_spec.rb`:

```ruby
require "rails_helper"

describe TranslationRun do
  let(:game)  { create_game }
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }

  # actor_id is null: false in the schema and belongs_to is required by
  # default, so every persisted run needs one.
  def persisted_run(attrs = {})
    TranslationRun.create!({ :game => game, :actor => actor,
                             :model => "claude-opus-5" }.merge(attrs))
  end

  # Comma-joined, not serialised: the same convention games.available_locales
  # uses, for the same reason -- it must be readable in a database console
  # during an incident.
  it "round-trips the target locale list through a comma-joined column" do
    run = TranslationRun.new(:game => game)
    run.target_locale_list = %w[en pl]

    expect(run.target_locales).to eq("en,pl")
    expect(run.target_locale_list).to eq(%w[en pl])
  end

  it "treats a blank column as an empty list rather than [\"\"]" do
    expect(TranslationRun.new(:game => game, :target_locales => "").target_locale_list).to eq([])
  end

  it "knows which states are terminal" do
    expect(TranslationRun.new(:state => "running").terminal?).to be false
    expect(TranslationRun.new(:state => "pending").terminal?).to be false
    %w[succeeded failed cancelled].each do |state|
      expect(TranslationRun.new(:state => state).terminal?).to be true
    end
  end

  it "reports progress as a fraction, and does not divide by zero on an empty run" do
    expect(TranslationRun.new(:fields_total => 0,  :fields_done => 0).progress_fraction).to eq(0.0)
    expect(TranslationRun.new(:fields_total => 80, :fields_done => 20).progress_fraction).to eq(0.25)
  end

  # One run per game at a time. Without this the pre-flight estimate, the
  # per-field cost cap and the audit trail all describe a world where a single
  # run is in flight, while two threads race to write proposals for the same
  # (record, field, locale).
  it "finds an in-flight run for a game and ignores terminal ones" do
    finished = persisted_run(:state => TranslationRun::SUCCEEDED)
    expect(TranslationRun.active_for(game)).to be_empty

    running = persisted_run(:state => TranslationRun::RUNNING)
    expect(TranslationRun.active_for(game).to_a).to eq([ running ])

    expect(finished.terminal?).to be true
  end

  it "requires the actor the schema insists on" do
    expect { TranslationRun.create!(:game => game, :model => "claude-opus-5") }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
```

Create `spec/models/translation_proposal_spec.rb`:

```ruby
require "rails_helper"

describe TranslationProposal do
  let(:game)  { create_game }
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:run) do
    TranslationRun.create!(:game => game, :actor => actor,
                           :state => TranslationRun::RUNNING, :model => "claude-opus-5")
  end
  let(:level) { create_level(:game => game) }

  def build_proposal(attrs = {})
    TranslationProposal.new({ :translation_run => run, :translatable => level,
                              :field => "text", :locale => "en",
                              :source_text => "Найдите табличку",
                              :proposed_text => "Find the sign",
                              :state => "pending" }.merge(attrs))
  end

  it "round-trips flags through a comma-joined column" do
    proposal = build_proposal
    proposal.flag_list = %w[identical length]

    expect(proposal.flags).to eq("identical,length")
    expect(proposal.flag_list).to eq(%w[identical length])
    expect(proposal.flagged?).to be true
  end

  it "is unflagged when the column is blank" do
    proposal = build_proposal(:flags => nil)

    expect(proposal.flag_list).to eq([])
    expect(proposal.flagged?).to be false
  end

  it "scopes to pending and to unflagged separately" do
    clean   = build_proposal.tap(&:save!)
    flagged = build_proposal(:field => "name", :flags => "identical").tap(&:save!)
    done    = build_proposal(:locale => "pl", :state => "accepted").tap(&:save!)

    expect(TranslationProposal.pending).to match_array([ clean, flagged ])
    expect(TranslationProposal.pending.unflagged).to eq([ clean ])
    expect(done.state).to eq("accepted")
  end

  # The unique index is what makes a killed run resumable instead of
  # duplicating work -- it is load-bearing, not hygiene.
  it "refuses a second proposal for the same field and locale in one run" do
    build_proposal.save!

    expect { build_proposal.save!(:validate => false) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

```bash
bundle exec rspec spec/models/translation_run_spec.rb spec/models/translation_proposal_spec.rb
```

Expected: FAIL with `uninitialized constant TranslationRun`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260816100000_create_translation_runs.rb`:

```ruby
# One AI translation run, and the proposals it produced.
#
# Two tables rather than writing straight into content_translations: nothing
# reaches a live game without a human action, so the publication gate
# (Game#declared_locales_are_translated_before_publication) can never be
# satisfied by text nobody looked at.
class CreateTranslationRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :translation_runs do |t|
      t.integer  :game_id,  :null => false
      t.integer  :actor_id, :null => false

      # Resolved from Setting at start time, then FROZEN on the row. Read live
      # instead and changing the setting mid-run yields a run whose proposals
      # came from two different models with no way to tell which is which.
      t.string   :model, :null => false

      t.string   :state, :null => false, :default => "pending"

      # Comma-joined, matching games.available_locales: a short list of ASCII
      # locale codes that has to be readable in a console during an incident.
      t.string   :target_locales, :null => false, :default => ""

      t.integer  :fields_total,  :null => false, :default => 0
      t.integer  :fields_done,   :null => false, :default => 0
      t.integer  :fields_failed, :null => false, :default => 0

      t.integer  :estimated_input_tokens, :null => false, :default => 0
      t.integer  :input_tokens,           :null => false, :default => 0
      t.integer  :output_tokens,          :null => false, :default => 0
      # Kept so the run page can show whether the prompt-caching structure in
      # the design's §3 is actually hitting, rather than the design merely
      # asserting that it does.
      t.integer  :cache_read_tokens,      :null => false, :default => 0

      t.text     :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :translation_runs, [ :game_id, :state ]

    create_table :translation_proposals do |t|
      t.integer  :translation_run_id, :null => false
      t.string   :translatable_type,  :null => false
      t.integer  :translatable_id,    :null => false
      t.string   :field,  :null => false
      t.string   :locale, :null => false

      # SNAPSHOTTED at translation time, for the same reason
      # AdminAction#target_label snapshots its target's name: if the level text
      # is later edited, a proposal that only pointed at the record would
      # silently start claiming to be a translation of text that no longer
      # exists. The snapshot is what makes this an audit trail, not a cache.
      t.text     :source_text,   :null => false
      t.text     :proposed_text, :null => false

      t.string   :flags
      t.string   :state, :null => false, :default => "pending"
      t.integer  :reviewed_by_id
      t.datetime :reviewed_at
      t.timestamps
    end

    # NOT hygiene. This index is the resumability mechanism: the runner skips
    # any (record, field, locale) that already has a proposal for this run, so
    # a thread killed by a deploy costs the level in flight, not the run.
    add_index :translation_proposals,
              [ :translation_run_id, :translatable_type, :translatable_id, :field, :locale ],
              :unique => true, :name => "index_translation_proposals_unique_field"
    add_index :translation_proposals, [ :translation_run_id, :state ]
  end
end
```

- [ ] **Step 4: Write the models**

Create `app/models/translation_run.rb`:

```ruby
# app/models/translation_run.rb
#
# One press of "Translate". Holds the work counters the run page renders and
# the token totals the run actually spent.
class TranslationRun < ApplicationRecord
  belongs_to :game
  belongs_to :actor, :class_name => "User"
  has_many :translation_proposals, :dependent => :destroy

  PENDING   = "pending".freeze
  RUNNING   = "running".freeze
  SUCCEEDED = "succeeded".freeze
  FAILED    = "failed".freeze
  CANCELLED = "cancelled".freeze

  TERMINAL_STATES = [ SUCCEEDED, FAILED, CANCELLED ].freeze
  ACTIVE_STATES   = [ PENDING, RUNNING ].freeze

  validates :model, :presence => true
  validates :state, :inclusion => { :in => ACTIVE_STATES + TERMINAL_STATES }

  scope :active_for, ->(game) { where(:game_id => game.id, :state => ACTIVE_STATES) }
  scope :newest_first, -> { order(:created_at => :desc) }

  # Same shape as Game#available_locale_list, deliberately -- an operator
  # reading either column in a console should not have to learn two formats.
  def target_locale_list
    self.target_locales.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def target_locale_list=(list)
    self.target_locales = Array(list).map(&:to_s).map(&:strip).reject(&:blank?).join(",")
  end

  def running?
    self.state == RUNNING
  end

  def terminal?
    TERMINAL_STATES.include?(self.state)
  end

  # Guarded, because a run whose work-list came out empty has fields_total 0
  # and the run page divides by this to draw the progress bar.
  def progress_fraction
    return 0.0 if self.fields_total.to_i.zero?

    self.fields_done.to_f / self.fields_total
  end
end
```

Create `app/models/translation_proposal.rb`:

```ruby
# app/models/translation_proposal.rb
#
# One field, translated by the model and not yet accepted. Accepting writes a
# ContentTranslation through the same setter the authoring form uses, so the
# stored row is byte-identical to a hand-typed one; the provenance lives here
# and the game never reads this table.
class TranslationProposal < ApplicationRecord
  belongs_to :translation_run
  belongs_to :translatable, :polymorphic => true
  belongs_to :reviewed_by, :class_name => "User", :optional => true

  PENDING  = "pending".freeze
  ACCEPTED = "accepted".freeze
  REJECTED = "rejected".freeze

  validates :field,         :presence => true
  validates :locale,        :presence => true
  validates :proposed_text, :presence => true
  validates :state, :inclusion => { :in => [ PENDING, ACCEPTED, REJECTED ] }

  scope :pending,   -> { where(:state => PENDING) }
  scope :unflagged, -> { where(:flags => [ nil, "" ]) }

  def flag_list
    self.flags.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def flag_list=(list)
    self.flags = Array(list).map(&:to_s).join(",")
  end

  def flagged?
    self.flag_list.any?
  end
end
```

- [ ] **Step 5: Migrate and run the specs to verify they pass**

```bash
bin/rails db:migrate && bin/rails db:test:prepare
bundle exec rspec spec/models/translation_run_spec.rb spec/models/translation_proposal_spec.rb
```

Expected: PASS, 10 examples (6 run + 4 proposal), 0 failures.

- [ ] **Step 6: Check autoloading and commit**

```bash
bin/rails zeitwerk:check
git add db/migrate db/schema.rb app/models/translation_run.rb app/models/translation_proposal.rb spec/models/translation_run_spec.rb spec/models/translation_proposal_spec.rb
git commit -m "Add translation run and proposal tables"
```

---

## Task 2: Generalise the work-list to any locale

**Files:**
- Modify: `app/models/game.rb:445-458`
- Test: `spec/models/game/translation_work_list_spec.rb`

**Interfaces:**
- Consumes: `Game#translatable_records` (private, `app/models/game.rb:619`), `Game#label_for` (private, `:638`), `Game::MissingTranslation` (`:10`).
- Produces:
  - `Game#missing_translated_fields_in(locale)` → `Array<Game::MissingTranslation>`, where `MissingTranslation` is a `Struct.new(:record, :field, :locale, :label)`. Task 6 consumes this.
  - `Game#label_for(record, field)` → `String`, **made public**. Task 9's review screen calls it from a view.

**Why:** `Game#missing_translations` hard-wires itself to `available_locale_list` at line 446. A superadmin needs to translate *into* a locale before declaring it — translate, then tick the box, then the publish gate passes. This is a pure extraction; existing behaviour must not move.

**Also:** `label_for` currently sits below `private` (line 557), so it is a private method. Task 9's review screen needs a human-readable name for each proposal's field — "Level 3, task text" — and that is exactly what `label_for` computes. It is made public here rather than snapshotted onto the proposal row, because the label is derived from position and field name and should render in *the reader's* current locale, not in whichever locale the superadmin happened to be using when the run started. `translatable_records` stays private.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/game/translation_work_list_spec.rb`:

```ruby
require "rails_helper"

describe Game, "#missing_translated_fields_in" do
  let(:game) do
    create_game(:primary_locale => "ru", :available_locale_list => %w[ru]).tap do |g|
      create_level(:game => g, :name => "Первый", :text => "Найдите табличку")
    end
  end

  # The whole point of the extraction: a locale that is not declared yet still
  # produces a work-list, so a superadmin can translate first and declare
  # second. missing_translations returns nothing here, correctly.
  it "returns work for a locale the game has not declared" do
    expect(game.missing_translations).to be_empty

    fields = game.missing_translated_fields_in("pl")

    expect(fields.map(&:field)).to match_array(%w[name description name text])
    expect(fields.map(&:locale).uniq).to eq([ "pl" ])
  end

  it "skips fields that already have a usable translation" do
    level = game.levels.first
    level.translations_attributes = { "pl" => { "name" => "Pierwszy" } }
    level.save!

    fields = game.missing_translated_fields_in("pl")

    expect(fields.select { |f| f.record == level }.map(&:field)).to eq([ "text" ])
  end

  it "labels every entry, so no blank instruction reaches the author's list" do
    expect(game.missing_translated_fields_in("pl").map(&:label)).to all(be_present)
  end

  # The review screen renders this from a view, so it has to be public. It is
  # not snapshotted onto the proposal row on purpose: the label is derived from
  # position and field name, and should render in the READER's locale rather
  # than in whichever locale the run happened to start in.
  it "exposes label_for publicly" do
    level = game.levels.first

    expect(game.label_for(level, "text")).to be_present
    expect { game.public_send(:label_for, level, "text") }.not_to raise_error
  end

  # Regression guard on the extraction: missing_translations must keep
  # answering exactly as before, because the publish gate depends on it.
  it "leaves missing_translations answering for declared locales only" do
    # Draft first: create_game leaves is_draft false, and
    # declared_locales_are_translated_before_publication refuses to let a
    # PUBLISHED game declare a locale it has not translated -- the gate working
    # correctly, and nothing to do with this extraction. A draft is exempt
    # (`return if self.draft?`), and that guard reads the value being saved, so
    # this first update! passes validation on its own.
    game.update!(:is_draft => true)
    game.update!(:available_locale_list => %w[ru pl])

    expect(game.missing_translations.map(&:locale).uniq).to eq([ "pl" ])
    expect(game.missing_translations.size).to eq(game.missing_translated_fields_in("pl").size)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/models/game/translation_work_list_spec.rb
```

Expected: FAIL with `undefined method 'missing_translated_fields_in'`.

- [ ] **Step 3: Extract the method**

In `app/models/game.rb`, replace lines 445–458 with:

```ruby
  # Split out of missing_translations so a locale that is not declared yet can
  # still produce a work-list: the AI translation feature translates first and
  # declares second, and the publish gate then passes. missing_translations
  # keeps its exact former behaviour, expressed in terms of this.
  def missing_translated_fields_in(locale)
    translatable_records.flat_map do |record|
      record.class::TRANSLATABLE_FIELDS.map do |field|
        next if record.translated?(field, locale)

        MissingTranslation.new(record, field, locale, label_for(record, field))
      end.compact
    end
  end

  def missing_translations
    non_primary = self.available_locale_list - [ self.primary_locale.to_s ]
    return [] if non_primary.empty?

    non_primary.flat_map { |locale| missing_translated_fields_in(locale) }
  end
```

- [ ] **Step 3b: Make `label_for` public**

`label_for` currently sits at line 638, below the `private` keyword at line 557. **Cut the whole method** — from its leading comment down to its `end` — and paste it into the public section, immediately after the `missing_translations` you just wrote. Add this comment above it:

```ruby
  # Public because the AI-translation review screen renders it from a view: a
  # proposal needs a human-readable name for the field it translates ("Level 3,
  # task text"), and this already computes exactly that. Deliberately not
  # snapshotted onto translation_proposals -- the label is derived from
  # position and field name, so it should render in the READER's locale, not in
  # whichever locale the run happened to start in.
```

Leave `translatable_records` (line 619) where it is; nothing outside the model calls it.

- [ ] **Step 4: Run the new spec and the existing translation specs together**

```bash
bundle exec rspec spec/models/game/translation_work_list_spec.rb \
                  spec/requests/publish_gate_spec.rb \
                  spec/requests/authoring_translations_spec.rb \
                  spec/requests/language_tabs_spec.rb
```

Expected: PASS, 0 failures. If `publish_gate_spec.rb` fails, the extraction changed behaviour — revert and redo it as a literal move.

- [ ] **Step 5: Commit**

```bash
git add app/models/game.rb spec/models/game/translation_work_list_spec.rb
git commit -m "Let the translation work-list answer for undeclared locales"
```

---

## Task 3: Settings for the model and the per-run cap

**Files:**
- Modify: `app/models/setting.rb` (constants near the top, `self.put`, validations, add `self.enum`)
- Modify: `app/controllers/admin/settings_controller.rb`
- Modify: `app/views/admin/settings/show.html.erb`
- Test: `spec/models/setting_translation_keys_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Setting::ENUM_DEFAULTS` → `{"translation_model" => "claude-opus-5"}`
  - `Setting::ENUM_ALLOWED` → `{"translation_model" => %w[claude-opus-5 claude-sonnet-5 claude-haiku-4-5]}`
  - `Setting.enum("translation_model")` → `String`
  - `Setting.integer("translation_max_fields_per_run")` → `Integer` (default `400`)

**Why a third category:** `translation_model` cannot ride `STRING_DEFAULTS`. That category is a *list* normalised by `Setting.normalise_list` and validated by `ENTRY = /\A(?=.*[a-z])[a-z0-9]{1,10}\z/` — which rejects hyphens and anything over ten characters, so `claude-opus-5` fails twice over. It also cannot be free text: the design requires an allow-list a superadmin can pick from but not widen.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/setting_translation_keys_spec.rb`:

```ruby
require "rails_helper"

describe Setting, "translation keys" do
  it "defaults the model to Claude Opus 5 with no row present" do
    expect(Setting.enum("translation_model")).to eq("claude-opus-5")
  end

  it "stores an allowed model" do
    Setting.put("translation_model", "claude-sonnet-5")

    expect(Setting.enum("translation_model")).to eq("claude-sonnet-5")
  end

  # An allow-list, not free text -- the same shape as allowed_extensions, which
  # a superadmin may narrow but must not be able to widen into something
  # dangerous. Here the hazard is a typo'd model ID that 404s every call of a
  # run, or a model nobody costed.
  it "refuses a model that is not on the allow-list" do
    expect { Setting.put("translation_model", "gpt-4") }
      .to raise_error(ActiveRecord::RecordInvalid)

    expect(Setting.enum("translation_model")).to eq("claude-opus-5")
  end

  it "refuses a model ID that only looks plausible" do
    expect { Setting.put("translation_model", "claude-opus-5-20260101") }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "caps the fields one run may translate" do
    expect(Setting.integer("translation_max_fields_per_run")).to eq(400)

    Setting.put("translation_max_fields_per_run", 50)
    expect(Setting.integer("translation_max_fields_per_run")).to eq(50)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/models/setting_translation_keys_spec.rb
```

Expected: FAIL with `undefined method 'enum' for Setting`.

- [ ] **Step 3: Add the third category to the model**

In `app/models/setting.rb`, add after `STRING_DEFAULTS`:

```ruby
  # Single-valued, chosen from a fixed set. A third category because neither
  # existing one fits: INTEGER_DEFAULTS is numeric, and STRING_DEFAULTS is a
  # LIST normalised by normalise_list and validated by ENTRY, which rejects
  # hyphens and anything over ten characters -- "claude-opus-5" fails that
  # twice over. Stored in string_value alongside the list keys; the two are
  # told apart by which hash the name appears in.
  ENUM_DEFAULTS = {
    "translation_model" => "claude-opus-5"
  }.freeze

  # An allow-list, not free text, for the same reason allowed_extensions is
  # intersected with a constant: a superadmin may choose among costed,
  # supported models but must not be able to introduce one nobody has tested.
  # Exact IDs -- never append a date suffix, which 404s.
  ENUM_ALLOWED = {
    "translation_model" => %w[claude-opus-5 claude-sonnet-5 claude-haiku-4-5].freeze
  }.freeze
```

Add `"translation_max_fields_per_run" => 400` to `STORAGE_DEFAULTS`'s sibling — create a new hash beside it and merge it in:

```ruby
  # Blast radius for one AI translation run. A whole game into every registered
  # locale is a few hundred fields; this is the ceiling that stops a mis-click
  # on a very large game from becoming a very large bill.
  TRANSLATION_DEFAULTS = {
    "translation_max_fields_per_run" => 400
  }.freeze
```

Then change the composed constants:

```ruby
  INTEGER_DEFAULTS = RATE_LIMIT_DEFAULTS.merge(STORAGE_DEFAULTS)
                                        .merge(TRANSLATION_DEFAULTS).freeze
```

Widen the name validation and add the enum validation:

```ruby
  validates :name, :presence => true, :uniqueness => true,
                   :inclusion => { :in => INTEGER_DEFAULTS.keys +
                                          STRING_DEFAULTS.keys +
                                          ENUM_DEFAULTS.keys }

  validate :enum_value_is_allowed, :if => :enum_key?
```

Add the reader beside `self.list`:

```ruby
  def self.enum(name)
    record = find_by(:name => name)
    return ENUM_DEFAULTS.fetch(name) if record.nil? || record.string_value.blank?

    record.string_value
  end
```

Extend `self.put` — the new branch goes **first**, because an enum key is not a list key and must not be run through `normalise_list`:

```ruby
  def self.put(name, value)
    record = find_or_initialize_by(:name => name)

    if ENUM_DEFAULTS.key?(name)
      record.string_value = value.to_s.strip
    elsif STRING_DEFAULTS.key?(name)
      record.string_value = normalise_list(value).join(" ")
    else
      record.value = value
    end

    record.save!
    record
  end
```

Add the private predicates beside `string_key?`:

```ruby
  def enum_key?
    ENUM_DEFAULTS.key?(name)
  end

  def enum_value_is_allowed
    return if self.class::ENUM_ALLOWED.fetch(name, []).include?(string_value)

    errors.add(:string_value, :inclusion)
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

```bash
bundle exec rspec spec/models/setting_translation_keys_spec.rb spec/requests/admin_settings_spec.rb
```

Expected: PASS. `admin_settings_spec.rb` must stay green — `translation_max_fields_per_run` joined `INTEGER_DEFAULTS`, which is what the admin page iterates, so it now renders a fifth (or later) numeric row.

- [ ] **Step 5: Render the enum on the admin settings page**

In `app/controllers/admin/settings_controller.rb`, widen the permitted list in `#update`:

```ruby
    permitted = Setting::INTEGER_DEFAULTS.keys + Setting::STRING_DEFAULTS.keys +
                Setting::ENUM_DEFAULTS.keys
```

and add the enum branch inside the transaction, **before** the string branch:

```ruby
          if Setting::ENUM_DEFAULTS.key?(name)
            Setting.put(name, value)
          elsif Setting::STRING_DEFAULTS.key?(name)
```

**Leave `#current_values` alone.** It must keep returning integer settings only:

```ruby
  def current_values
    Setting::INTEGER_DEFAULTS.keys.index_with { |name| Setting.integer(name) }
  end
```

Merging the enum into it looks harmless and is not: the view's pre-existing loop iterates `@values` to render **number fields**, so a merged enum renders `translation_model` twice — once as a numeric input holding a model name, once as the correct select — with a duplicate DOM id and two controls fighting over one form parameter.

In `app/views/admin/settings/show.html.erb`, add a select after the existing loops, reading the setting **directly**, exactly as the `STRING_DEFAULTS` loop immediately above it already does:

```erb
  <% Setting::ENUM_DEFAULTS.each_key do |name| %>
    <div class="field">
      <%= label_tag "settings_#{name}", t("admin.settings.names.#{name}") %>
      <%# Read directly rather than through @values, exactly as the
          STRING_DEFAULTS loop above does. Merging enums into @values would
          also feed them to the number-field loop, which renders a numeric
          input for a model name and duplicates the id and the form field. %>
      <%= select_tag "settings[#{name}]",
                     options_for_select(Setting::ENUM_ALLOWED.fetch(name), Setting.enum(name)),
                     :id => "settings_#{name}" %>
    </div>
  <% end %>
```

Add one example to `spec/requests/admin_settings_spec.rb` asserting the page renders exactly one control per setting name — `translation_model` as a select, not also as a number field. Nothing in the existing suite catches a duplicated form field, which is how the merged-`current_values` version got as far as a rendered page before anyone noticed.

- [ ] **Step 6: Add the two label keys to all seven locales**

Under `admin.settings.names` in each of `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`, add `translation_model` and `translation_max_fields_per_run`. Russian and English:

```yaml
# ru.yml
        translation_model: "Модель для перевода"
        translation_max_fields_per_run: "Максимум полей за один перевод"
# en.yml
        translation_model: "Translation model"
        translation_max_fields_per_run: "Maximum fields per translation run"
```

- [ ] **Step 7: Run the i18n and settings specs, then commit**

```bash
bundle exec rspec spec/i18n_spec.rb spec/models/setting_translation_keys_spec.rb spec/requests/admin_settings_spec.rb
git add app/models/setting.rb app/controllers/admin/settings_controller.rb app/views/admin/settings/show.html.erb config/locales spec/models/setting_translation_keys_spec.rb
git commit -m "Add translation model and per-run field cap to settings"
```

---

## Task 4: Mechanical quality flags for proposals

**Files:**
- Create: `app/services/translation/flags.rb`
- Test: `spec/services/translation/flags_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Translation::Flags.for(:source => String, :proposed => String)` → `Array<String>`, values drawn from `%w[empty identical lost_digits lost_latin length]`.

**Why this task carries the feature's real safety:** a superadmin reviewing Polish usually cannot evaluate Polish. These five checks need no knowledge of the target language and between them catch the structural failures that would otherwise pass review and satisfy the publish gate. `identical` in particular guards the exact failure documented at `app/models/concerns/translatable_content.rb:49-62`, where saving an unedited pre-filled form persisted **Russian labelled as English**.

- [ ] **Step 1: Write the failing spec**

Create `spec/services/translation/flags_spec.rb`:

```ruby
require "rails_helper"

describe Translation::Flags do
  def flags_for(source, proposed)
    described_class.for(:source => source, :proposed => proposed)
  end

  it "returns nothing for an ordinary good translation" do
    expect(flags_for("Найдите табличку на стене", "Find the sign on the wall")).to eq([])
  end

  it "flags empty and whitespace-only output" do
    expect(flags_for("Найдите табличку", "")).to include("empty")
    expect(flags_for("Найдите табличку", "   \n ")).to include("empty")
  end

  # THE important one. This is the failure translatable_content.rb:49-62
  # documents: text saved unchanged in another language's slot, which then
  # satisfies the publish gate. An automated translator that echoes its input
  # reproduces that at scale.
  it "flags output byte-identical to the source" do
    expect(flags_for("Найдите табличку", "Найдите табличку")).to include("identical")
  end

  it "ignores surrounding whitespace when deciding identity" do
    expect(flags_for("Найдите табличку", "  Найдите табличку  ")).to include("identical")
  end

  # Answers in this game are codes players type. Translating one silently
  # breaks the game for every team.
  it "flags a digit sequence present in the source but missing from the output" do
    expect(flags_for("Код на двери: 4417", "The code on the door")).to include("lost_digits")
  end

  it "does not flag digits that survived" do
    expect(flags_for("Код на двери: 4417", "The door code is 4417")).not_to include("lost_digits")
  end

  it "flags a Latin-script token present in the source but missing from the output" do
    expect(flags_for("Ищите вывеску BETA", "Look for the sign")).to include("lost_latin")
  end

  it "does not flag Latin tokens introduced by the translation itself" do
    expect(flags_for("Найдите табличку", "Find the sign")).not_to include("lost_latin")
  end

  it "flags output far shorter or far longer than the source" do
    source = "а" * 100
    expect(flags_for(source, "б" * 30)).to include("length")
    expect(flags_for(source, "б" * 300)).to include("length")
    expect(flags_for(source, "б" * 100)).not_to include("length")
  end

  it "does not raise the length flag on very short source strings" do
    expect(flags_for("Да", "Yes")).not_to include("length")
  end

  # The source here is deliberately free of digits and Latin: an empty
  # proposal against a source containing a code would also raise lost_digits,
  # and a source under MIN_LENGTH_FOR_RATIO characters cannot raise length at
  # all. Both traps have to be avoided for this example to demonstrate what it
  # claims to.
  it "can return several flags at once" do
    expect(flags_for("Найдите табличку на стене подъезда", "")).to match_array(%w[empty length])
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/services/translation/flags_spec.rb
```

Expected: FAIL with `uninitialized constant Translation`.

- [ ] **Step 3: Implement the checks**

Create `app/services/translation/flags.rb`:

```ruby
# app/services/translation/flags.rb
#
# Structural checks a reviewer who does not read the target language can still
# act on.
#
# This is the safety story for the whole feature. A superadmin reviewing Polish
# cannot evaluate Polish wording; what they CAN act on is a proposal that is
# empty, that echoes its input, that dropped a code, or whose length is
# implausible. None of these five needs the reviewer to know the language.
module Translation
  module Flags
    # Below this, length ratios are noise: "Да" -> "Yes" is a 150% expansion
    # and perfectly correct.
    MIN_LENGTH_FOR_RATIO = 20

    SHORT_RATIO = 0.4
    LONG_RATIO  = 2.5

    DIGITS = /\d+/
    # Two or more Latin letters, so a stray initial does not trip the check.
    LATIN  = /[A-Za-z]{2,}/

    def self.for(source:, proposed:)
      source   = source.to_s
      proposed = proposed.to_s

      flags = []
      flags << "empty"       if proposed.strip.empty?
      flags << "identical"   if !proposed.strip.empty? && proposed.strip == source.strip
      flags << "lost_digits" if lost?(DIGITS, source, proposed)
      flags << "lost_latin"  if lost?(LATIN,  source, proposed)
      flags << "length"      if implausible_length?(source, proposed)
      flags
    end

    # Asymmetric on purpose: a token the SOURCE contains and the proposal does
    # not is a dropped code. A token the proposal introduces is just the target
    # language -- "Find the sign" is full of Latin and entirely correct.
    def self.lost?(pattern, source, proposed)
      (source.scan(pattern) - proposed.scan(pattern)).any?
    end

    def self.implausible_length?(source, proposed)
      return false if source.strip.length < MIN_LENGTH_FOR_RATIO

      ratio = proposed.strip.length.to_f / source.strip.length
      ratio < SHORT_RATIO || ratio > LONG_RATIO
    end

    private_class_method :lost?, :implausible_length?
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

```bash
bundle exec rspec spec/services/translation/flags_spec.rb
```

Expected: PASS, 11 examples, 0 failures.

- [ ] **Step 5: Mutation-test the checks**

Each check must have an example that fails when the check is deleted. Verify by hand, one at a time — comment out each of the five `flags <<` lines, re-run, confirm a **red** result, then restore:

```bash
# Repeat for each of the five lines. Every one must produce a failure.
bundle exec rspec spec/services/translation/flags_spec.rb
```

Expected each time: at least one FAIL. A check whose removal leaves the suite green is a check that is not tested — add the missing example before moving on.

- [ ] **Step 6: Commit**

```bash
git add app/services/translation/flags.rb spec/services/translation/flags_spec.rb
git commit -m "Flag structurally suspect translation proposals"
```

---

## Task 5: The Claude client seam

**Files:**
- Modify: `Gemfile`
- Create: `app/services/translation/unit.rb`
- Create: `app/services/translation/client.rb`
- Test: `spec/services/translation/unit_spec.rb`
- Test: `spec/services/translation/client_spec.rb`

**Interfaces:**
- Consumes: `Game::MissingTranslation` from Task 2.
- Produces:
  - `Translation::Unit` — a value object for one cacheable prompt unit. `Translation::Unit.for_game(game, fields)` and `Translation::Unit.for_level(level, fields)` → `Unit`; instance methods `#key` → `String`, `#source_text` → `String`, `#fields` → `Array<Game::MissingTranslation>`, and `Unit.field_key(record, field)` → `String` such as `"Level#12.name"`.
  - `Translation::Client.new(api_key:, model:)`, `#translate(unit:, locale:)` → `Translation::Client::Result` with `#texts` → `Hash{String => String}` keyed by field key, `#input_tokens`, `#output_tokens`, `#cache_read_tokens`. Raises `Translation::Client::Error` on refusal or transport failure.
  - `Translation::Client.configured?` → Boolean (`ENV["ANTHROPIC_API_KEY"].present?`).

- [ ] **Step 1: Add the gem**

In `Gemfile`, after `gem "bcrypt", "~> 3.1"`:

```ruby
# Claude API, for superadmin-triggered translation of author-written game
# content. Loaded only when a translation run actually starts -- see
# Translation::Client.
gem "anthropic", "~> 1.0"
```

```bash
bundle install
```

- [ ] **Step 2: Write the failing unit spec**

Create `spec/services/translation/unit_spec.rb`:

```ruby
require "rails_helper"

describe Translation::Unit do
  let(:game)  { create_game(:name => "Ночной город", :description => "Городская игра") }
  let!(:level) { create_level(:game => game, :name => "Первый", :text => "Найдите табличку 4417") }
  let!(:hint)  { create_hint(:level => level, :text => "Смотрите выше", :delay => 10) }

  it "keys a field unambiguously by class, id and field name" do
    expect(described_class.field_key(level, "name")).to eq("Level##{level.id}.name")
    expect(described_class.field_key(hint, "text")).to eq("Hint##{hint.id}.text")
  end

  it "builds a game-header unit carrying only the game's own fields" do
    fields = game.missing_translated_fields_in("en").select { |f| f.record == game }
    unit   = described_class.for_game(game, fields)

    expect(unit.key).to eq("Game##{game.id}")
    expect(unit.source_text).to include("Ночной город").and include("Городская игра")
    expect(unit.fields.map(&:field)).to match_array(%w[name description])
  end

  # The level subtree is the cacheable unit AND the context unit: a hint that
  # says "смотрите выше" is meaningless without the level text it refers to,
  # so both ride the same prompt.
  it "builds a level unit carrying the level, its hints and its options" do
    fields = game.missing_translated_fields_in("en").select do |f|
      f.record == level || f.record.try(:level) == level
    end
    unit = described_class.for_level(level, fields)

    expect(unit.key).to eq("Level##{level.id}")
    expect(unit.source_text).to include("Найдите табличку 4417").and include("Смотрите выше")
    expect(unit.source_text).to include(described_class.field_key(hint, "text"))
  end

  it "carries no unit at all when nothing in the subtree is missing" do
    expect(described_class.for_level(level, [])).to be_nil
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bundle exec rspec spec/services/translation/unit_spec.rb
```

Expected: FAIL with `uninitialized constant Translation::Unit`.

- [ ] **Step 4: Implement the unit**

Create `app/services/translation/unit.rb`:

```ruby
# app/services/translation/unit.rb
#
# One cacheable prompt unit: either the game's own header fields, or a whole
# level subtree (the level, its hints, and its questions' options).
#
# The subtree is the unit for two reasons that happen to agree. Quality: game
# content is referential -- a hint says "look at the sign you found", and
# translated in isolation the pronoun has no referent. Cost: this is the
# cheapest shape per unit of translated text, because a per-field call re-sends
# the rules every time and is far too short to reach Claude Opus 5's 512-token
# minimum cacheable prefix, so nothing ever caches at all.
module Translation
  class Unit
    attr_reader :key, :fields

    def self.field_key(record, field)
      "#{record.class.name}##{record.id}.#{field}"
    end

    def self.for_game(game, fields)
      return nil if fields.empty?

      new("Game##{game.id}", fields)
    end

    def self.for_level(level, fields)
      return nil if fields.empty?

      new("Level##{level.id}", fields)
    end

    def initialize(key, fields)
      @key    = key
      @fields = fields
    end

    # Every field is labelled with the key the model must echo back, so the
    # response maps to records without positional guessing.
    def source_text
      @fields.map do |missing|
        "#{self.class.field_key(missing.record, missing.field)}: #{missing.record[missing.field]}"
      end.join("\n\n")
    end
  end
end
```

- [ ] **Step 5: Run the unit spec to verify it passes**

```bash
bundle exec rspec spec/services/translation/unit_spec.rb
```

Expected: PASS, 4 examples.

- [ ] **Step 6: Write the failing client spec**

Create `spec/services/translation/client_spec.rb`:

```ruby
require "rails_helper"

describe Translation::Client do
  let(:game)   { create_game(:name => "Ночной город") }
  let(:fields) { game.missing_translated_fields_in("pl").select { |f| f.record == game } }
  let(:unit)   { Translation::Unit.for_game(game, fields) }
  let(:client) { described_class.new(:api_key => "sk-ant-test", :model => "claude-opus-5") }

  # The SDK is stubbed at exactly one seam. No spec in this feature touches the
  # network.
  let(:messages) { double("messages") }

  before { allow(client).to receive(:messages).and_return(messages) }

  def api_response(translations, usage: {})
    double("message",
           :stop_reason => :end_turn,
           :content => [ double("block", :type => :text,
                                :text => { "translations" => translations }.to_json) ],
           :usage => double("usage",
                            :input_tokens  => usage.fetch(:input, 100),
                            :output_tokens => usage.fetch(:output, 50),
                            :cache_read_input_tokens => usage.fetch(:cache_read, 0)))
  end

  it "returns translated text keyed by field key" do
    key = Translation::Unit.field_key(game, "name")
    allow(messages).to receive(:create)
      .and_return(api_response([ { "key" => key, "text" => "Nocne miasto" } ]))

    result = client.translate(:unit => unit, :locale => "pl")

    expect(result.texts).to eq(key => "Nocne miasto")
  end

  it "carries usage back so the run can prove its caching is hitting" do
    allow(messages).to receive(:create)
      .and_return(api_response([], :usage => { :input => 900, :output => 300, :cache_read => 800 }))

    result = client.translate(:unit => unit, :locale => "pl")

    expect(result.input_tokens).to eq(900)
    expect(result.output_tokens).to eq(300)
    expect(result.cache_read_tokens).to eq(800)
  end

  # The cache breakpoint sits on the SOURCE block, so the only thing after it
  # is "translate into X". Move it and every locale after the first becomes a
  # cache miss.
  it "puts the cache breakpoint on the source block, with the locale after it" do
    expect(messages).to receive(:create) do |args|
      expect(args[:system_].last[:cache_control]).to eq({ :type => "ephemeral" })
      expect(args[:system_].last[:text]).to include("Ночной город")
      expect(args[:messages].first[:content]).to include("Polski")
      expect(args[:output_config][:effort]).to eq("low")
      api_response([])
    end

    client.translate(:unit => unit, :locale => "pl")
  end

  # stop_reason is read BEFORE content. Code that indexes content[0]
  # unconditionally breaks on a refusal, and production is a bad place to
  # find that out.
  it "raises rather than reading content when the model refuses" do
    allow(messages).to receive(:create)
      .and_return(double("message", :stop_reason => :refusal, :stop_details => nil,
                                    :content => [], :usage => nil))

    expect { client.translate(:unit => unit, :locale => "pl") }
      .to raise_error(Translation::Client::Error, /refus/i)
  end

  it "knows whether an API key is configured at all" do
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
    expect(described_class.configured?).to be false

    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("sk-ant-x")
    expect(described_class.configured?).to be true
  end
end
```

- [ ] **Step 7: Run it to verify it fails**

```bash
bundle exec rspec spec/services/translation/client_spec.rb
```

Expected: FAIL with `uninitialized constant Translation::Client`.

- [ ] **Step 8: Implement the client**

Create `app/services/translation/client.rb`:

```ruby
# app/services/translation/client.rb
#
# The ONLY place in this application that touches the Anthropic SDK. Every spec
# in the feature stubs this seam, so no spec needs a network or a key.
module Translation
  class Client
    Error = Class.new(StandardError)

    Result = Struct.new(:texts, :input_tokens, :output_tokens, :cache_read_tokens,
                        :keyword_init => true)

    # An array of {key, text} rather than an object with dynamic property
    # names: JSON Schema cannot express "one property per field", and a fixed
    # schema is what lets strict validation happen at the tool-call layer --
    # so a malformed response is retried by the API, not by a parse-failure
    # loop here that would burn a second full call.
    RESPONSE_SCHEMA = {
      "type" => "object",
      "properties" => {
        "translations" => {
          "type"  => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "key"  => { "type" => "string" },
              "text" => { "type" => "string" }
            },
            "required" => [ "key", "text" ],
            "additionalProperties" => false
          }
        }
      },
      "required" => [ "translations" ],
      "additionalProperties" => false
    }.freeze

    # The rule that matters most is about codes, not language. Answer is not a
    # translatable model, so answers are never sent -- but a level's text or a
    # hint can QUOTE a code the player must type, and translating one silently
    # breaks the game for every team.
    RULES = <<~PROMPT.freeze
      You translate content for an urban puzzle game. Each input line is
      "KEY: TEXT". Return one entry per key, translating only TEXT.

      Rules:
      - Copy verbatim, never translate: digit sequences, codes, coordinates,
        times, house numbers, URLs, and Latin-script proper nouns. A player
        types these exactly as printed; a translated code breaks the game.
      - Preserve line breaks and paragraph structure exactly.
      - Keep the register of the original. This is read under time pressure.
      - Translate every key you are given, and invent no keys.
    PROMPT

    def self.configured?
      ENV["ANTHROPIC_API_KEY"].present?
    end

    def initialize(api_key:, model:)
      @api_key = api_key
      @model   = model
    end

    def translate(unit:, locale:)
      response = messages.create(
        :model      => @model,
        :max_tokens => 8_000,
        :output_config => {
          # The single largest cost lever after model choice. NOT
          # thinking: {type: "disabled"} -- on Claude Opus 5 that has a
          # documented tendency to leak <thinking> tags into the visible
          # response, which here would land verbatim inside a game level.
          :effort => "low",
          :format => { :type => "json_schema", :schema => RESPONSE_SCHEMA }
        },
        :system_ => [
          { :type => "text", :text => RULES },
          # The breakpoint. Everything up to and including this block is
          # identical across every target locale for this unit, so the first
          # locale writes the cache at 1.25x and the rest read it at 0.1x.
          { :type => "text", :text => unit.source_text,
            :cache_control => { :type => "ephemeral" } }
        ],
        :messages => [
          { :role => "user", :content => "Translate the above into #{language_name(locale)}." }
        ]
      )

      # Before content, always.
      raise Error, "model refused: #{response.stop_reason}" if response.stop_reason == :refusal

      build_result(response)
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}"
    end

    private

    def messages
      @messages ||= ::Anthropic::Client.new(:api_key => @api_key).messages
    end

    # The language's own name, which is what the locale switcher already shows.
    def language_name(locale)
      I18n.t("locales.#{locale}", :locale => locale)
    end

    def build_result(response)
      block = response.content.find { |b| b.type == :text }
      raise Error, "no text block in response" if block.nil?

      payload = JSON.parse(block.text)
      texts   = payload.fetch("translations", []).each_with_object({}) do |entry, acc|
        acc[entry["key"]] = entry["text"]
      end

      usage = response.usage
      Result.new(
        :texts             => texts,
        :input_tokens      => usage&.input_tokens.to_i,
        :output_tokens     => usage&.output_tokens.to_i,
        :cache_read_tokens => usage&.cache_read_input_tokens.to_i
      )
    end
  end
end
```

- [ ] **Step 9: Run the client spec to verify it passes**

```bash
bundle exec rspec spec/services/translation/
```

Expected: PASS, all examples. If `messages` cannot be stubbed because it is private, change the spec's `allow(client).to receive(:messages)` — RSpec stubs private methods fine, so this should work as written.

- [ ] **Step 10: Commit**

```bash
git add Gemfile Gemfile.lock app/services/translation spec/services/translation
git commit -m "Add the Claude client seam and prompt units"
```

---

## Task 6: The runner

**Files:**
- Create: `app/services/translation/runner.rb`
- Test: `spec/services/translation/runner_spec.rb`

**Interfaces:**
- Consumes: `Game#missing_translated_fields_in` (Task 2), `Translation::Unit` and `Translation::Client` (Task 5), `Translation::Flags` (Task 4), `TranslationRun` / `TranslationProposal` (Task 1).
- Produces: `Translation::Runner.new(run, client: nil)`, `#call` → `void`. Also `Translation::Runner.plan(game, locales)` → `Array<Game::MissingTranslation>` (the flat work-list, used by the controller for the pre-flight count).

- [ ] **Step 1: Write the failing spec**

Create `spec/services/translation/runner_spec.rb`:

```ruby
require "rails_helper"

describe Translation::Runner do
  let(:actor)  { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)   { create_game(:primary_locale => "ru", :available_locale_list => %w[ru]) }
  let!(:level) { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }

  let(:run) do
    TranslationRun.create!(:game => game, :actor => actor, :model => "claude-opus-5",
                           :state => TranslationRun::PENDING,
                           :target_locale_list => %w[en pl],
                           :fields_total => described_class.plan(game, %w[en pl]).size)
  end

  # A fake standing in for Translation::Client. Records the order calls were
  # made in, which is how the caching structure is asserted.
  class FakeClient
    attr_reader :calls

    def initialize(&behaviour)
      @calls = []
      @behaviour = behaviour
    end

    def translate(unit:, locale:)
      @calls << [ unit.key, locale ]
      @behaviour&.call(unit, locale)

      texts = unit.fields.each_with_object({}) do |missing, acc|
        key = Translation::Unit.field_key(missing.record, missing.field)
        acc[key] = "[#{locale}] #{missing.record[missing.field]}"
      end

      Translation::Client::Result.new(:texts => texts, :input_tokens => 100,
                                      :output_tokens => 50, :cache_read_tokens => 10)
    end
  end

  it "writes one proposal per missing field per locale" do
    described_class.new(run, :client => FakeClient.new).call

    expect(run.reload.state).to eq(TranslationRun::SUCCEEDED)
    expect(run.translation_proposals.count).to eq(run.fields_total)
    expect(run.translation_proposals.pluck(:locale).uniq).to match_array(%w[en pl])
    expect(run.fields_done).to eq(run.fields_total)
  end

  # THE cost-critical assertion. Levels outer, locales inner: the source block
  # stays in place across a unit's locales, so every locale after the first
  # reads the cached prefix. Reverse the loops and every call is a miss.
  it "translates each unit into every locale before moving to the next unit" do
    client = FakeClient.new
    described_class.new(run, :client => client).call

    units = client.calls.map(&:first)

    # Contiguity IS the property. A unit's calls must not be interrupted by
    # another unit's: the cached prefix is that unit's source text, so once
    # another unit's prompt has replaced it, coming back costs full price.
    # chunk collapses only CONSECUTIVE runs, so a unit reappearing later
    # survives into the result and breaks this equality.
    #
    # Do NOT write this as `units.chunk_while { |a, b| a == b }.flat_map { |c| c }`.
    # That round-trip is the identity function for every input — it compares an
    # array to itself and asserts nothing whatsoever.
    expect(units.chunk { |u| u }.map(&:first)).to eq(units.uniq)

    # ...and each unit sees every target locale, in order. Expressed against the
    # run's own locale list rather than a literal slice width, so adding a third
    # target locale cannot silently misalign it. This second assertion does NOT
    # catch a reversal on its own — group_by collapses non-contiguous calls.
    per_unit = client.calls.group_by(&:first).values.map { |calls| calls.map(&:last) }
    expect(per_unit.uniq).to eq([ run.target_locale_list ])
  end

  it "snapshots the source text and flags each proposal" do
    described_class.new(run, :client => FakeClient.new).call

    proposal = run.translation_proposals.find_by(:field => "text", :locale => "en")
    expect(proposal.source_text).to eq("Найдите табличку")
    expect(proposal.proposed_text).to eq("[en] Найдите табличку")
    expect(proposal.flag_list).to eq([])
  end

  it "accumulates token usage onto the run" do
    described_class.new(run, :client => FakeClient.new).call

    expect(run.reload.cache_read_tokens).to be > 0
    expect(run.input_tokens).to be > 0
  end

  # Resumability. The unique index is the mechanism; this proves it works.
  it "skips fields that already have a proposal when re-entered" do
    described_class.new(run, :client => FakeClient.new).call
    written = run.translation_proposals.count

    run.update!(:state => TranslationRun::RUNNING, :fields_done => 0)
    second = FakeClient.new
    described_class.new(run, :client => second).call

    expect(run.translation_proposals.count).to eq(written)
    expect(second.calls).to be_empty
  end

  it "records a failed unit and carries on to the next one" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    boom = FakeClient.new do |unit, _locale|
      raise Translation::Client::Error, "429" if unit.key.start_with?("Level")
    end
    described_class.new(run, :client => boom).call

    expect(run.reload.fields_failed).to be > 0
    expect(run.state).to eq(TranslationRun::SUCCEEDED)
    expect(run.translation_proposals.where(:translatable_type => "Game")).to be_present
  end

  it "stops when the run is cancelled mid-flight" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    # update_all through a separate relation, deliberately. `run.update_column`
    # would write the in-memory attribute too, so a naive in-memory
    # `@run.state == CANCELLED` check — precisely the bug the runner's
    # DB-backed `cancelled?` exists to avoid — would satisfy this example.
    cancelling = FakeClient.new do
      TranslationRun.where(:id => run.id).update_all(:state => TranslationRun::CANCELLED)
    end
    described_class.new(run, :client => cancelling).call

    expect(run.reload.state).to eq(TranslationRun::CANCELLED)
    expect(cancelling.calls.size).to eq(1)
  end

  # Both counters describe THIS pass. Without the reset, a run that fails and
  # then succeeds on retry keeps reporting failures that no longer exist.
  it "clears the previous pass's failure count and message on a clean retry" do
    create_level(:game => game, :name => "Второй", :text => "Идите дальше")
    run.update!(:fields_total => described_class.plan(game, %w[en pl]).size)

    boom = FakeClient.new do |unit, _locale|
      raise Translation::Client::Error, "429" if unit.key.start_with?("Level")
    end
    described_class.new(run, :client => boom).call
    expect(run.reload.fields_failed).to be > 0
    expect(run.error_message).to be_present

    run.update!(:state => TranslationRun::RUNNING)
    described_class.new(run, :client => FakeClient.new).call

    expect(run.reload.fields_failed).to eq(0)
    expect(run.error_message).to be_nil
    expect(run.fields_done).to eq(run.fields_total)
  end

  it "counts a field the model omitted as failed rather than losing it" do
    omitted_key = Translation::Unit.field_key(game, "description")

    # Drop one key from whatever FakeClient would otherwise return -- but
    # only for one locale, so exactly one (record, field, locale) triple is
    # missing rather than one per locale.
    partial = Class.new(FakeClient) do
      define_method(:translate) do |unit:, locale:|
        result = super(:unit => unit, :locale => locale)
        result.texts.delete(omitted_key) if locale == "en"
        result
      end
    end.new

    described_class.new(run, :client => partial).call

    expect(run.reload.fields_failed).to eq(1)
    # The invariant that makes a run's self-report trustworthy: every field is
    # accounted for exactly once, either done or failed, never neither.
    expect(run.fields_done + run.fields_failed).to eq(run.fields_total)
    expect(run.translation_proposals.count).to eq(run.fields_total - 1)
    # No proposal row for the omitted field -- that is what lets the
    # resumability rule retry exactly it on a later pass.
    expect(
      run.translation_proposals.exists?(:translatable_type => "Game",
                                        :field => "description", :locale => "en")
    ).to eq(false)
  end

  it "never proposes for the game's primary locale" do
    run.update!(:target_locale_list => %w[ru en])
    described_class.new(run, :client => FakeClient.new).call

    expect(run.translation_proposals.pluck(:locale).uniq).to eq([ "en" ])
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/services/translation/runner_spec.rb
```

Expected: FAIL with `uninitialized constant Translation::Runner`.

- [ ] **Step 3: Implement the runner**

Create `app/services/translation/runner.rb`:

```ruby
# app/services/translation/runner.rb
#
# Walks a game's missing translatable fields and turns them into proposals.
#
# The loop order is the single cost-critical decision in this feature: UNITS
# OUTER, LOCALES INNER. Prompt caching is a strict prefix match, and the prompt
# is [rules][this unit's source][translate into X]. Holding the unit still
# while the locales vary means every locale after the first reads a cached
# prefix at a tenth of the price. Reverse the loops and, by the time the first
# unit comes round again, the prefix has been replaced once per unit -- every
# single call is a cache miss.
#
# The locale calls must also stay SEQUENTIAL: a cache entry only becomes
# readable once the first response begins streaming, so firing a unit's locales
# concurrently means all of them pay full price. Nothing is waiting on this
# work, so sequential costs nothing.
module Translation
  class Runner
    def self.plan(game, locales)
      locales.reject { |l| l.to_s == game.primary_locale.to_s }
             .flat_map { |locale| game.missing_translated_fields_in(locale) }
    end

    def initialize(run, client: nil)
      @run    = run
      @client = client
    end

    def call
      # fields_failed and error_message both describe THIS pass. Without the
      # reset, a run that fails four fields and then succeeds them on a retry
      # still reports four failures that no longer exist — and the failure
      # count is what an author uses to decide whether another pass is needed.
      @run.update!(:state => TranslationRun::RUNNING, :started_at => Time.now,
                   :fields_failed => 0, :error_message => nil)

      units.each do |unit|
        locales.each do |locale|
          return finish(TranslationRun::CANCELLED) if cancelled?

          translate(unit, locale)
        end
      end

      finish(TranslationRun::SUCCEEDED)
    rescue StandardError => e
      @run.update!(:state => TranslationRun::FAILED, :error_message => e.message,
                   :finished_at => Time.now)
    end

    private

    def locales
      @locales ||= @run.target_locale_list.reject { |l| l == @run.game.primary_locale.to_s }
    end

    # Grouped by unit, and the game header first so a run that dies early has
    # still produced the game's own name and description.
    def units
      game   = @run.game
      fields = locales.flat_map { |locale| game.missing_translated_fields_in(locale) }
      by_locale_agnostic = fields.uniq { |f| [ f.record.class.name, f.record.id, f.field ] }

      header = Unit.for_game(game, by_locale_agnostic.select { |f| f.record == game })
      levels = game.levels.map do |level|
        Unit.for_level(level, by_locale_agnostic.select { |f| owning_level(f.record) == level.id })
      end

      ([ header ] + levels).compact
    end

    def owning_level(record)
      case record
      when Level    then record.id
      when Hint     then record.level_id
      when Question then record.level_id
      when Option   then record.question&.level_id
      end
    end

    def cancelled?
      @run.class.where(:id => @run.id).pick(:state) == TranslationRun::CANCELLED
    end

    def translate(unit, locale)
      outstanding = unit.fields.reject { |f| already_proposed?(f, locale) }
      return if outstanding.empty?

      result = client.translate(:unit => unit, :locale => locale)
      record_proposals(outstanding, locale, result)
    rescue Client::Error => e
      # Per unit, never per run. A field that failed simply has no proposal
      # row, so the resumability rule re-runs exactly the failed fields.
      @run.increment!(:fields_failed, outstanding.size)
      @run.update_column(:error_message, e.message)
    end

    def already_proposed?(missing, locale)
      @run.translation_proposals.exists?(
        :translatable_type => missing.record.class.name,
        :translatable_id   => missing.record.id,
        :field             => missing.field,
        :locale            => locale
      )
    end

    def record_proposals(outstanding, locale, result)
      TranslationProposal.transaction do
        outstanding.each do |missing|
          text = result.texts[Unit.field_key(missing.record, missing.field)]
          # The model omitted this field. Counted as FAILED rather than
          # silently skipped: with no proposal row it is retried by the
          # resumability rule above, and a run must never report success over
          # fields it never actually produced. Skipping it leaves
          # fields_done + fields_failed < fields_total on a succeeded run —
          # "47 of 50, no failures", with nothing anywhere naming the three.
          if text.nil?
            @run.increment!(:fields_failed)
            next
          end

          source = missing.record[missing.field].to_s
          TranslationProposal.create!(
            :translation_run => @run,
            :translatable    => missing.record,
            :field           => missing.field,
            :locale          => locale,
            :source_text     => source,
            :proposed_text   => text,
            :flags           => Flags.for(:source => source, :proposed => text).join(","),
            :state           => TranslationProposal::PENDING
          )
          @run.increment!(:fields_done)
        end

        @run.increment!(:input_tokens,      result.input_tokens)
        @run.increment!(:output_tokens,     result.output_tokens)
        @run.increment!(:cache_read_tokens, result.cache_read_tokens)
      end
    end

    def finish(state)
      @run.update!(:state => state, :finished_at => Time.now)
    end

    def client
      @client ||= Client.new(:api_key => ENV["ANTHROPIC_API_KEY"], :model => @run.model)
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

```bash
bundle exec rspec spec/services/translation/runner_spec.rb
```

Expected: PASS, 10 examples.

**One subtlety to expect while reading `#units`:** the work-list is deduplicated with `uniq { [class, id, field] }`, which collapses the per-locale copies of the same field down to one `MissingTranslation`. The surviving struct still carries *a* locale — whichever came first — and that value is **deliberately ignored**. A `Unit` is locale-agnostic by construction: `source_text` reads `missing.record[missing.field]`, the primary-language column, and the target locale enters only through the user turn. That is exactly what makes one unit reusable across every locale, which is the entire basis of the caching structure.

- [ ] **Step 5: Commit**

```bash
git add app/services/translation/runner.rb spec/services/translation/runner_spec.rb
git commit -m "Translate a game unit by unit, locales inner"
```

---

## Task 7: Routes, controller, authorization and audit

**Files:**
- Modify: `config/routes.rb` (inside the existing top-level `resources :games do ... end` block)
- Create: `app/controllers/translation_runs_controller.rb`
- Create: `app/views/translation_runs/new.html.erb`
- Test: `spec/requests/translation_run_authorization_spec.rb`
- Test: `spec/requests/translation_runs_spec.rb`
- Modify: `spec/requests/admin_audit_spec.rb`

**Note on the view:** `new.html.erb` lands here, not in Task 9, because this task's own authorization spec does `get new_game_translation_run_path(game)` and expects 200 — which renders it. A task whose tests render a template owns that template.

**Interfaces:**
- Consumes: `Translation::Runner.plan` and `Translation::Runner` (Task 6), `Translation::Client.configured?` (Task 5), `Setting.enum` / `Setting.integer` (Task 3), `TranslationRun.active_for` (Task 1).
- Produces: routes `game_translation_runs_path(game)` (POST create, GET new), `game_translation_run_path(game, run)` (GET show), `cancel_game_translation_run_path(game, run)` (POST).

- [ ] **Step 1: Write the failing authorization spec**

Create `spec/requests/translation_run_authorization_spec.rb`:

```ruby
require "rails_helper"

describe "translation run authorization", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before { allow(Translation::Client).to receive(:configured?).and_return(true) }

  # Deliberately require_superadmin!, NOT ensure_author. ensure_author is a
  # marked security chokepoint that already admits superadmins to author
  # actions; this feature spends real money against a shared API key, so the
  # author of a game must not reach it.
  #
  # Status is :unauthorized (401), not 403: ApplicationController's
  # deny_unauthorized renders status: :unauthorized for every
  # Authentication::Unauthorized this app raises (see
  # spec/requests/superadmin_authorization_spec.rb, "refuses a stranger"), and
  # require_superadmin! raises exactly that. Asserting 403 here would diverge
  # from every other superadmin-gated action in the app for no reason specific
  # to this controller.
  it "refuses the game's own author" do
    sign_in(author)

    post game_translation_runs_path(game), :params => { :locales => [ "en" ] }
    expect(response).to have_http_status(:unauthorized)

    get new_game_translation_run_path(game)
    expect(response).to have_http_status(:unauthorized)
  end

  # A guest is refused earlier and differently, same as every other
  # authenticated-only action: require_authentication! runs before
  # require_superadmin!, raises Authentication::Unauthenticated, and
  # deny_unauthenticated redirects to the login form (302), not a 401/403 --
  # see superadmin_authorization_spec.rb's "still refuses an anonymous
  # visitor" for the same pattern on ensure_author.
  it "refuses a guest" do
    post game_translation_runs_path(game), :params => { :locales => [ "en" ] }
    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(login_path)
  end

  it "admits a superadmin" do
    sign_in(superadmin)
    get new_game_translation_run_path(game)

    expect(response.status).to eq(200)
  end

  # With no key the feature does not exist at all -- development and CI need
  # no credential. require_api_key! raises the same Authentication::Unauthorized
  # as require_superadmin!, so the status matches (401, not 403).
  it "refuses everyone when no API key is configured" do
    allow(Translation::Client).to receive(:configured?).and_return(false)
    sign_in(superadmin)

    post game_translation_runs_path(game), :params => { :locales => [ "en" ] }
    expect(response).to have_http_status(:unauthorized)
  end
end
```

**Route helper names are singular for `new`.** Rails generates `new_game_translation_run_path` (singular). The plural `new_game_translation_runs_path` does not exist and will raise `NoMethodError`. Check `bin/rails routes | grep translation_run` rather than guessing; the same slip appears in Task 8's spec and Task 9's view if copied from here.

- [ ] **Step 2: Write the failing behaviour spec**

Create `spec/requests/translation_runs_spec.rb`:

```ruby
require "rails_helper"

describe "starting a translation run", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:primary_locale => "ru", :available_locale_list => %w[ru]) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    create_level(:game => game, :name => "Первый", :text => "Найдите табличку")
    allow(Translation::Client).to receive(:configured?).and_return(true)
    # The thread is not started in specs; the run's creation is what is under
    # test here, and the runner has its own spec.
    allow(Translation::Runner).to receive(:new).and_return(double(:call => nil))
    sign_in(superadmin)
  end

  it "creates a run carrying the model resolved at start time" do
    Setting.put("translation_model", "claude-sonnet-5")

    expect { post game_translation_runs_path(game), :params => { :locales => %w[en pl] } }
      .to change { TranslationRun.count }.by(1)

    run = TranslationRun.newest_first.first
    expect(run.model).to eq("claude-sonnet-5")
    expect(run.target_locale_list).to eq(%w[en pl])
    expect(run.fields_total).to be > 0
    expect(response).to redirect_to(game_translation_run_path(game, run))
  end

  it "refuses a second run while one is already in flight" do
    TranslationRun.create!(:game => game, :actor => superadmin, :model => "claude-opus-5",
                           :state => TranslationRun::RUNNING)

    expect { post game_translation_runs_path(game), :params => { :locales => [ "en" ] } }
      .not_to change { TranslationRun.count }

    expect(flash[:alert]).to eq(I18n.t("translations.runs.already_running"))
  end

  it "refuses a run larger than the configured cap" do
    Setting.put("translation_max_fields_per_run", 1)

    expect { post game_translation_runs_path(game), :params => { :locales => %w[en pl] } }
      .not_to change { TranslationRun.count }

    expect(flash[:alert]).to be_present
  end

  it "refuses a run with nothing to do" do
    expect { post game_translation_runs_path(game), :params => { :locales => [ "ru" ] } }
      .not_to change { TranslationRun.count }
  end

  it "lets a superadmin cancel a running run" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::RUNNING)

    post cancel_game_translation_run_path(game, run)

    expect(run.reload.state).to eq(TranslationRun::CANCELLED)
  end
end
```

- [ ] **Step 3: Run both to verify they fail**

```bash
bundle exec rspec spec/requests/translation_run_authorization_spec.rb spec/requests/translation_runs_spec.rb
```

Expected: FAIL with `undefined local variable or method 'game_translation_runs_path'`.

- [ ] **Step 4: Add the routes**

In `config/routes.rb`, inside the existing top-level `resources :games do` block (the one with `delete :delete` etc., around line 108), add:

```ruby
    # AI translation of author-written content. Superadmin-only; nested under
    # the game because every action needs the game in scope and the redirect
    # target is the game's edit screen.
    #
    # POST for cancel, not DELETE: this app has no Turbo and no rails-ujs, so
    # the view drives it with a real button_to form.
    resources :translation_runs, :only => [ :new, :create, :show ] do
      post :cancel, :on => :member
    end
```

- [ ] **Step 5: Write the controller**

Create `app/controllers/translation_runs_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# Superadmin-triggered AI translation of a game's author-written content.
#
# The run happens in a Thread rather than a job: this application has no
# ActiveJob backend (:inline in all three environments) and the production host
# has one vCPU and roughly 1.1 GB spare, so a queue backend would cost a second
# container for a feature used a few times a week. Progress is persisted per
# field instead, which is what makes a killed thread resumable.
class TranslationRunsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!
  before_action :load_game
  before_action :require_api_key!

  def new
    @locales = I18n.available_locales.map(&:to_s) - [ @game.primary_locale.to_s ]
  end

  def create
    locales = Array(params[:locales]).map(&:to_s) & I18n.available_locales.map(&:to_s)
    work    = Translation::Runner.plan(@game, locales)

    return refuse("empty")           if work.empty?
    return refuse("already_running") if TranslationRun.active_for(@game).exists?
    return refuse("too_large", :count => Setting.integer("translation_max_fields_per_run")) if
      work.size > Setting.integer("translation_max_fields_per_run")

    run = begin
            TranslationRun.create!(
              :game => @game, :actor => current_user,
              # Frozen here, deliberately: reading the Setting live would let a
              # change mid-run produce proposals from two models with no way to
              # tell which.
              :model => Setting.enum("translation_model"),
              :state => TranslationRun::PENDING,
              :target_locale_list => locales,
              :fields_total => work.size
            )
          rescue ActiveRecord::RecordNotUnique
            # Lost the race against a concurrent POST. The guard above is
            # check-then-act and cannot be sufficient on its own; the partial
            # unique index is what enforces the invariant, and this is where
            # losing lands. Same message either way -- the operator does not
            # need to know which of the two paths refused them.
            return refuse("already_running")
          end

    start(run)
    record_admin_action("translation_run_started", @game,
                        "locales=#{locales.join(",")} fields=#{work.size} model=#{run.model}")
    redirect_to game_translation_run_path(@game, run)
  end

  def show
    @run = @game.translation_runs.find(params[:id])
  end

  def cancel
    run = @game.translation_runs.find(params[:id])
    run.update!(:state => TranslationRun::CANCELLED, :finished_at => Time.now)

    record_admin_action("translation_run_cancelled", @game, "run=#{run.id}")
    redirect_to game_translation_run_path(@game, run)
  end

  private

  def load_game
    @game = Game.find(params[:game_id])
  end

  # With no key the feature does not exist. The views also hide every entry
  # point, but a guard at the controller is what makes that a rule rather than
  # a rendering detail.
  def require_api_key!
    raise Authentication::Unauthorized, t("errors.must_be_superadmin") unless
      Translation::Client.configured?
  end

  def refuse(reason, options = {})
    flash[:alert] = t("translations.runs.#{reason}", **options)
    redirect_to edit_game_path(@game)
  end

  # Rails.application.executor.wrap is load-bearing, not ceremony: a bare
  # Thread leaks a connection from the pool and does not participate in code
  # reloading. On a host with ~1.1 GB spare, leaked connections are not
  # theoretical.
  def start(run)
    Thread.new do
      Rails.application.executor.wrap do
        Translation::Runner.new(run).call
      end
    end
  end
end
```

Add the association to `app/models/game.rb`, beside the other `has_many` declarations:

```ruby
  has_many :translation_runs, :dependent => :destroy
```

- [ ] **Step 5b: Enforce one active run per game in the database**

The guard in `#create` is check-then-act: `active_for(@game).exists?` and
`create!` are two statements, and under Puma's multi-threaded default two
concurrent POSTs both pass it. That is not exotic input — `new.html.erb` is a
plain submit a browser double-posts on a double-click, and Task 9 puts one
`button_to` per locale on the edit screen. What is at stake is a duplicate
**bill**, not a duplicate row: `Runner#already_proposed?` de-duplicates within
a run, so a second run re-translates every field the first is already paying
for.

Create `db/migrate/20260816110000_add_one_active_run_per_game_index.rb`:

```ruby
# One active translation run per game, enforced by the database.
#
# Partial index, not a plain unique index on game_id: a game legitimately
# accumulates many terminal (succeeded/failed/cancelled) runs over time, and
# only the active ones (pending/running) must be mutually exclusive.
#
# Partial indexes work on both SQLite (dev/test) and Postgres (production), so
# this is enforced everywhere, not just where a lock happens to be honoured.
class AddOneActiveRunPerGameIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :translation_runs, :game_id, :unique => true,
              :where => "state IN (\'pending\', \'running\')",
              :name => "index_translation_runs_one_active_per_game"
  end
end
```

```bash
bin/rails db:migrate && bin/rails db:test:prepare
```

Add three examples to `spec/requests/translation_runs_spec.rb`: that a second
active run for one game raises `ActiveRecord::RecordNotUnique`; that a
**terminal** run does not block a new one (the index is partial for exactly
that reason); and that losing the race refuses with the same flash rather than
500ing. Stub `TranslationRun.active_for` to return `TranslationRun.none` to
simulate the interleaving in that last one.

- [ ] **Step 6: Write the locale-picker template**

Create `app/views/translation_runs/new.html.erb`:

```erb
<h2><%= t("translations.new.heading", :game => @game.name) %></h2>

<%= form_with url: game_translation_runs_path(@game), method: :post do %>
  <% @locales.each do |locale| %>
    <label>
      <%= check_box_tag "locales[]", locale, false %>
      <%= t("locales.#{locale}") %>
    </label>
  <% end %>
  <%= submit_tag t("translations.new.submit"), :class => "btn btn--go" %>
<% end %>

<em><%= link_to t("shared.cancel"), edit_game_path(@game) %></em>
```

- [ ] **Step 7: Add the flash and picker strings to all seven locales**

Add to each of `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` under a new `translations:` top-level key. Russian and English shown; translate the other five (`uk ka tr be pl`).

**Turkish note:** `translations.new.heading` interpolates `%{game}`, a name an author typed. Turkish cannot attach a case suffix to a placeholder — put the suffix on a common noun instead, as the other 37 such keys in this repository do: `«%{game}» adlı oyun`.

```yaml
# ru.yml
  translations:
    runs:
      already_running: "Для этой игры уже выполняется перевод."
      too_large: "Слишком много полей за один раз (максимум %{count})."
      empty: "Нечего переводить: для выбранных языков переводы уже есть."
    new:
      heading: "Перевод игры «%{game}»"
      submit: "Перевести"
# en.yml
  translations:
    runs:
      already_running: "A translation is already running for this game."
      too_large: "Too many fields for one run (maximum %{count})."
      empty: "Nothing to translate: the selected languages are already complete."
    new:
      heading: "Translating “%{game}”"
      submit: "Translate"
```

- [ ] **Step 8: Run the request specs to verify they pass**

```bash
bundle exec rspec spec/requests/translation_run_authorization_spec.rb \
                  spec/requests/translation_runs_spec.rb \
                  spec/i18n_spec.rb
```

Expected: PASS. `show` has no template yet — that is fine, because no spec in this task renders it: `create` redirects and `cancel` redirects. Do **not** create `show.html.erb` here; it belongs to Task 9, which tests it.

- [ ] **Step 9: Extend the audit spec deliberately**

`spec/requests/admin_audit_spec.rb` enumerates the audited actions and is the guard that a new action was considered rather than forgotten. Add inside `describe "the explicitly superadmin actions"`:

```ruby
    it "records the start of a translation run against the game" do
      allow(Translation::Client).to receive(:configured?).and_return(true)
      allow(Translation::Runner).to receive(:new).and_return(double(:call => nil))
      create_level(:game => game, :name => "Первый", :text => "Найдите табличку")

      expect { post game_translation_runs_path(game), :params => { :locales => [ "en" ] } }
        .to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("translation_run_started")
      expect(entry.target_type).to eq("Game")
      expect(entry.details).to include("model=")
    end
```

- [ ] **Step 10: Run the audit spec and commit**

```bash
bundle exec rspec spec/requests/admin_audit_spec.rb
git add config/routes.rb app/controllers/translation_runs_controller.rb app/views/translation_runs app/models/game.rb config/locales spec/requests
git commit -m "Start and cancel translation runs as a superadmin"
```

---

## Task 8: Accepting and rejecting proposals

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/translation_proposals_controller.rb`
- Test: `spec/requests/translation_proposal_review_spec.rb`
- Modify: `spec/requests/admin_audit_spec.rb`

**Interfaces:**
- Consumes: `TranslationProposal` (Task 1), `TranslatableContent#translations_attributes=` (existing, `app/models/concerns/translatable_content.rb:71`).
- Produces: routes `game_translation_run_proposals_path(game, run)` (GET index), `accept_..._proposal_path`, `reject_..._proposal_path` (POST members), `accept_all_game_translation_run_proposals_path` (POST collection).

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/translation_proposal_review_spec.rb`:

```ruby
require "rails_helper"

describe "reviewing translation proposals", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # :is_draft is load-bearing in this fixture, not decoration. create_game
  # leaves a game PUBLISHED, and declared_locales_are_translated_before_publication
  # refuses to let a published game declare a locale it has not translated --
  # so a `ru en` game blows up on save! before any example body runs. A draft
  # is exempt (`return if self.draft?`), which is what these specs want anyway.
  let(:game)       { create_game(:is_draft => true, :primary_locale => "ru",
                                 :available_locale_list => %w[ru en]) }
  let!(:level)     { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }
  let(:run) do
    TranslationRun.create!(:game => game, :actor => superadmin, :model => "claude-opus-5",
                           :state => TranslationRun::SUCCEEDED, :target_locale_list => %w[en])
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def proposal_for(record, field, text, flags: nil)
    TranslationProposal.create!(:translation_run => run, :translatable => record,
                                :field => field, :locale => "en",
                                :source_text => record[field].to_s, :proposed_text => text,
                                :flags => flags, :state => TranslationProposal::PENDING)
  end

  before do
    allow(Translation::Client).to receive(:configured?).and_return(true)
    sign_in(superadmin)
  end

  # The whole requirement in one assertion: an accepted proposal is
  # indistinguishable from a hand-typed translation, because it goes through
  # the same setter the authoring form uses.
  it "writes a ContentTranslation indistinguishable from a hand-typed one" do
    proposal = proposal_for(level, "name", "The first")

    post accept_game_translation_run_proposal_path(game, run, proposal)

    expect(proposal.reload.state).to eq(TranslationProposal::ACCEPTED)
    expect(proposal.reviewed_by_id).to eq(superadmin.id)
    expect(level.reload.translated("name", "en")).to eq("The first")

    row = ContentTranslation.find_by(:translatable => level, :field => "name", :locale => "en")
    expect(row.value).to eq("The first")
    # No provenance column on content_translations. The game cannot tell.
    expect(ContentTranslation.column_names).not_to include("source", "translation_run_id")
  end

  it "lets the reviewer edit before accepting" do
    proposal = proposal_for(level, "name", "The frist")

    post accept_game_translation_run_proposal_path(game, run, proposal),
         :params => { :proposed_text => "The first" }

    expect(level.reload.translated("name", "en")).to eq("The first")
    expect(proposal.reload.proposed_text).to eq("The first")
  end

  it "writes nothing when a proposal is rejected" do
    proposal = proposal_for(level, "name", "Первый")

    post reject_game_translation_run_proposal_path(game, run, proposal)

    expect(proposal.reload.state).to eq(TranslationProposal::REJECTED)
    expect(ContentTranslation.where(:translatable => level, :locale => "en")).to be_empty
  end

  # Accept-all is the bulk action, and it must never sweep up a flagged
  # proposal -- the flags exist precisely because those need a human eye.
  it "accepts every unflagged proposal and leaves flagged ones alone" do
    clean   = proposal_for(level, "name", "The first")
    flagged = proposal_for(level, "text", "Найдите табличку", :flags => "identical")

    post accept_all_game_translation_run_proposals_path(game, run)

    expect(clean.reload.state).to eq(TranslationProposal::ACCEPTED)
    expect(flagged.reload.state).to eq(TranslationProposal::PENDING)
  end

  it "completes the publish gate once every proposal is accepted" do
    proposal_for(game,  "name",        "Night city")
    proposal_for(game,  "description", "A city game")
    proposal_for(level, "name",        "The first")
    proposal_for(level, "text",        "Find the sign")

    post accept_all_game_translation_run_proposals_path(game, run)

    expect(game.reload.translations_complete?).to be true
  end

  it "refuses a non-superadmin" do
    proposal = proposal_for(level, "name", "The first")
    sign_in(create_user)

    post accept_game_translation_run_proposal_path(game, run, proposal)
    # 401, not 403: deny_unauthorized renders :unauthorized for every
    # Authentication::Unauthorized this app raises. See Task 7's spec.
    expect(response).to have_http_status(:unauthorized)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/requests/translation_proposal_review_spec.rb
```

Expected: FAIL with an undefined path helper.

- [ ] **Step 3: Add the nested routes**

In `config/routes.rb`, replace the `resources :translation_runs` block added in Task 7 with:

```ruby
    resources :translation_runs, :only => [ :new, :create, :show ] do
      post :cancel, :on => :member

      resources :proposals, :only => [ :index ],
                            :controller => "translation_proposals" do
        member do
          post :accept
          post :reject
        end
        post :accept_all, :on => :collection
      end
    end
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/translation_proposals_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# Reviewing what the model produced, before any of it reaches a live game.
#
# Accepting writes through TranslatableContent#translations_attributes=, the
# same setter GamesController, LevelsController, HintsController and
# OptionsController use for a hand-typed translation. That is deliberate: the
# stored ContentTranslation row is byte-identical to a human's, and the
# provenance lives only in translation_proposals, which the game never reads.
class TranslationProposalsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!
  before_action :load_run

  def index
    @proposals = @run.translation_proposals
                     .includes(:translatable)
                     .order(:locale, :translatable_type, :translatable_id, :field)
  end

  def accept
    # .pending, not a bare find: without it, rejecting an already-ACCEPTED
    # proposal marks it rejected while leaving the ContentTranslation it wrote
    # live in the game -- the review record and the game disagreeing about
    # whether the machine text was accepted. Accepting twice would likewise
    # write a second audit entry for one change.
    proposal = @run.translation_proposals.pending.find(params[:id])
    apply(proposal, params[:proposed_text].presence || proposal.proposed_text)

    record_admin_action("translation_proposals_accepted", @game,
                        "run=#{@run.id} proposals=1 locale=#{proposal.locale}")
    redirect_to game_translation_run_proposals_path(@game, @run)
  end

  def reject
    # .pending, not a bare find: without it, rejecting an already-ACCEPTED
    # proposal marks it rejected while leaving the ContentTranslation it wrote
    # live in the game -- the review record and the game disagreeing about
    # whether the machine text was accepted. Accepting twice would likewise
    # write a second audit entry for one change.
    proposal = @run.translation_proposals.pending.find(params[:id])
    proposal.update!(:state => TranslationProposal::REJECTED,
                     :reviewed_by => current_user, :reviewed_at => Time.now)

    redirect_to game_translation_run_proposals_path(@game, @run)
  end

  # Never sweeps up a flagged proposal. The flags exist precisely because those
  # are the ones a human has to look at, and a bulk action that ignored them
  # would make the whole review step decorative.
  def accept_all
    accepted = @run.translation_proposals.pending.unflagged.to_a
    accepted.each { |proposal| apply(proposal, proposal.proposed_text) }

    record_admin_action("translation_proposals_accepted", @game,
                        "run=#{@run.id} proposals=#{accepted.size}")
    redirect_to game_translation_run_proposals_path(@game, @run)
  end

  private

  def load_run
    @game = Game.find(params[:game_id])
    @run  = @game.translation_runs.find(params[:translation_run_id])
  end

  def apply(proposal, text)
    record = proposal.translatable
    record.translations_attributes = { proposal.locale => { proposal.field => text } }
    record.save!

    proposal.update!(:proposed_text => text, :state => TranslationProposal::ACCEPTED,
                     :reviewed_by => current_user, :reviewed_at => Time.now)
  end
end
```

- [ ] **Step 5: Run the spec to verify it passes**

```bash
bundle exec rspec spec/requests/translation_proposal_review_spec.rb
```

Expected: PASS, 7 examples. No template is needed in this task: every example POSTs and asserts a redirect or a database change, and nothing here renders `index`. Do **not** create `translation_proposals/index.html.erb` — it belongs to Task 9, which is the first task to `GET` it.

- [ ] **Step 6: Extend the audit spec and commit**

Add to `spec/requests/admin_audit_spec.rb`, inside the same describe block:

```ruby
    it "records an acceptance of translation proposals against the game" do
      run = TranslationRun.create!(:game => game, :actor => superadmin,
                                   :model => "claude-opus-5", :state => "succeeded")
      level = create_level(:game => game, :name => "Первый", :text => "Найдите табличку")
      TranslationProposal.create!(:translation_run => run, :translatable => level,
                                  :field => "name", :locale => "en",
                                  :source_text => "Первый", :proposed_text => "The first",
                                  :state => "pending")

      expect { post accept_all_game_translation_run_proposals_path(game, run) }
        .to change { AdminAction.count }.by(1)

      expect(AdminAction.newest_first.first.action).to eq("translation_proposals_accepted")
    end
```

```bash
bundle exec rspec spec/requests/admin_audit_spec.rb
git add config/routes.rb app/controllers/translation_proposals_controller.rb spec/requests
git commit -m "Review and accept translation proposals"
```

---

## Task 9: Views

**Files:**
- Modify: `app/views/games/edit.html.erb:47-63`
- Create: `app/views/translation_runs/show.html.erb`
- Create: `app/views/translation_proposals/index.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/translation_views_spec.rb`

**Interfaces:**
- Consumes: everything from Tasks 7 and 8.
- Produces: no new Ruby interfaces.

- [ ] **Step 1: Write the failing view spec**

Create `spec/requests/translation_views_spec.rb`:

```ruby
require "rails_helper"

describe "translation screens", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:author)     { create_user }

  # :is_draft is load-bearing in this fixture, not decoration. create_game
  # leaves a game PUBLISHED, and declared_locales_are_translated_before_publication
  # refuses to let a published game declare a locale it has not translated --
  # so a `ru en` game blows up on save! before any example body runs. A draft
  # is exempt (`return if self.draft?`), which is what these specs want anyway.
  let(:game)       { create_game(:author => author, :is_draft => true,
                                 :primary_locale => "ru",
                                 :available_locale_list => %w[ru en]) }
  let!(:level)     { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before { allow(Translation::Client).to receive(:configured?).and_return(true) }

  it "offers a Translate button per locale to a superadmin on the edit screen" do
    sign_in(superadmin)
    get edit_game_path(game)

    expect(response.body).to include(game_translation_runs_path(game))
    expect(response.body).to include(I18n.t("translations.edit.translate"))
  end

  it "offers nothing to the author, who cannot use the feature" do
    sign_in(author)
    get edit_game_path(game)

    expect(response.body).not_to include(I18n.t("translations.edit.translate"))
  end

  it "offers nothing when no API key is configured" do
    allow(Translation::Client).to receive(:configured?).and_return(false)
    sign_in(superadmin)
    get edit_game_path(game)

    expect(response.body).not_to include(I18n.t("translations.edit.translate"))
  end

  # Polling with no JavaScript at all. The refresh must disappear the moment
  # the run is terminal, or a finished page reloads forever.
  it "auto-refreshes only while the run is still going" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::RUNNING,
                                 :fields_total => 4, :fields_done => 1)
    sign_in(superadmin)

    get game_translation_run_path(game, run)
    expect(response.body).to include("http-equiv=\"refresh\"")
    expect(response.body).to include(I18n.t("translations.show.progress", :done => 1, :total => 4))

    run.update!(:state => TranslationRun::SUCCEEDED)
    get game_translation_run_path(game, run)
    expect(response.body).not_to include("http-equiv=\"refresh\"")
  end

  it "shows source beside proposal and names each flag on the review screen" do
    run = TranslationRun.create!(:game => game, :actor => superadmin,
                                 :model => "claude-opus-5", :state => TranslationRun::SUCCEEDED)
    TranslationProposal.create!(:translation_run => run, :translatable => level,
                                :field => "text", :locale => "en",
                                :source_text => "Найдите табличку",
                                :proposed_text => "Найдите табличку",
                                :flags => "identical", :state => "pending")
    sign_in(superadmin)

    get game_translation_run_proposals_path(game, run)

    expect(response.body).to include("Найдите табличку")
    expect(response.body).to include(I18n.t("translations.flags.identical"))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/requests/translation_views_spec.rb
```

Expected: FAIL — missing template or missing translation key.

- [ ] **Step 3: Add the triggers to the game edit screen**

In `app/views/games/edit.html.erb`, the `available_locale_list` field currently loops `I18n.available_locales` (lines 47–63). The Translate buttons must sit **outside** the `form_with` block — a nested form is invalid HTML and the inner one is dropped. Add this immediately *after* the closing `<% end %>` of the `form_with` block:

```erb
<%# AI translation. Superadmin-only and hidden entirely without an API key, so
    an author never sees a control they cannot use. Outside the form above:
    button_to renders its own <form>, and forms do not nest. %>
<% if logged_in? && current_user.superadmin? && Translation::Client.configured? %>
  <div class="translate-panel">
    <h3><%= t("translations.edit.heading") %></h3>
    <ul class="translate-locales">
      <% (I18n.available_locales.map(&:to_s) - [ @game.primary_locale.to_s ]).each do |locale| %>
        <li>
          <%= t("locales.#{locale}") %>
          <%= button_to t("translations.edit.translate"),
                        game_translation_runs_path(@game),
                        :params => { :"locales[]" => locale },
                        :class => "btn" %>
        </li>
      <% end %>
    </ul>
    <%= link_to t("translations.edit.translate_multiple"), new_game_translation_run_path(@game) %>
  </div>
<% end %>
```

- [ ] **Step 4: Write the two templates**

`app/views/translation_runs/new.html.erb` already exists — Task 7 created it, because Task 7's authorization spec renders it. Do not recreate it.

Create `app/views/translation_runs/show.html.erb`:

```erb
<% content_for :head do %>
  <%# Polling with no JavaScript. This app has no Turbo and no rails-ujs, and
      adopting either is an explicit non-goal -- rack-test executes no
      JavaScript, so the acceptance suite would be blind to it. Removed the
      moment the run is terminal, or a finished page reloads forever. %>
  <% unless @run.terminal? %>
    <meta http-equiv="refresh" content="3">
  <% end %>
<% end %>

<h2><%= t("translations.show.heading", :game => @game.name) %></h2>

<p>
  <%= t("translations.show.state.#{@run.state}") %> —
  <%= t("translations.show.progress", :done => @run.fields_done, :total => @run.fields_total) %>
</p>

<dl>
  <dt><%= t("translations.show.model") %></dt><dd><%= @run.model %></dd>
  <dt><%= t("translations.show.locales") %></dt>
  <dd><%= @run.target_locale_list.map { |l| t("locales.#{l}") }.join(", ") %></dd>
  <dt><%= t("translations.show.tokens") %></dt>
  <dd><%= t("translations.show.token_counts", :input => @run.input_tokens,
                                              :output => @run.output_tokens,
                                              :cached => @run.cache_read_tokens) %></dd>
  <% if @run.fields_failed.to_i > 0 %>
    <dt><%= t("translations.show.failed") %></dt><dd><%= @run.fields_failed %></dd>
  <% end %>
</dl>

<% if @run.running? %>
  <%= button_to t("translations.show.cancel"), cancel_game_translation_run_path(@game, @run),
                :class => "btn" %>
<% else %>
  <%= link_to t("translations.show.review"),
              game_translation_run_proposals_path(@game, @run), :class => "btn btn--go" %>
<% end %>

<em><%= link_to t("shared.cancel"), edit_game_path(@game) %></em>
```

Create `app/views/translation_proposals/index.html.erb`:

```erb
<h2><%= t("translations.review.heading", :game => @game.name) %></h2>

<%= button_to t("translations.review.accept_all"),
              accept_all_game_translation_run_proposals_path(@game, @run),
              :class => "btn btn--go" %>

<table class="proposals">
  <% @proposals.each do |proposal| %>
    <tr class="<%= "flagged" if proposal.flagged? %>">
      <td><%= t("locales.#{proposal.locale}") %></td>
      <td><%= @game.label_for(proposal.translatable, proposal.field) %></td>
      <%# Rendered as text, never as HTML. Author-written game content is
          escaped everywhere in this application and a translation of it is
          no different. %>
      <td class="source"><%= proposal.source_text %></td>
      <td>
        <%= form_with url: accept_game_translation_run_proposal_path(@game, @run, proposal),
                      method: :post do %>
          <%= text_area_tag "proposed_text", proposal.proposed_text, :rows => 3 %>
          <% if proposal.flagged? %>
            <ul class="flags">
              <% proposal.flag_list.each do |flag| %>
                <li><%= t("translations.flags.#{flag}") %></li>
              <% end %>
            </ul>
          <% end %>
          <%= submit_tag t("translations.review.accept"), :class => "btn btn--go" %>
        <% end %>
        <%= button_to t("translations.review.reject"),
                      reject_game_translation_run_proposal_path(@game, @run, proposal),
                      :class => "btn" %>
      </td>
      <td><%= t("translations.review.state.#{proposal.state}") %></td>
    </tr>
  <% end %>
</table>
```

- [ ] **Step 5: Add every new key to all seven locales**

Extend the `translations:` block in each of `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`. Russian and English shown; translate the other five (`uk ka tr be pl`).

**Turkish note:** `translations.new.heading` and the others interpolate `%{game}`, a name an author typed. Turkish cannot attach a case suffix to a placeholder — put the suffix on a common noun instead, as the other 37 such keys in this repository do: `«%{game}» adlı oyun`.

```yaml
# ru.yml — extends the translations: block added in Task 7
  translations:
    edit:
      heading: "Перевод с помощью ИИ"
      translate: "Перевести"
      translate_multiple: "Перевести на несколько языков…"
    show:
      heading: "Перевод игры «%{game}»"
      progress: "%{done} из %{total}"
      model: "Модель"
      locales: "Языки"
      tokens: "Токены"
      token_counts: "ввод %{input}, вывод %{output}, из кэша %{cached}"
      failed: "Не переведено"
      cancel: "Остановить"
      review: "Проверить перевод"
      state:
        pending: "Ожидает"
        running: "Выполняется"
        succeeded: "Завершён"
        failed: "Ошибка"
        cancelled: "Остановлен"
    review:
      heading: "Проверка перевода игры «%{game}»"
      accept_all: "Принять всё без замечаний"
      accept: "Принять"
      reject: "Отклонить"
      state:
        pending: "Ожидает"
        accepted: "Принято"
        rejected: "Отклонено"
    flags:
      empty: "Пустой перевод"
      identical: "Совпадает с оригиналом — возможно, не переведено"
      lost_digits: "Потерян код или число"
      lost_latin: "Потеряно латинское слово или ссылка"
      length: "Подозрительная длина"
# en.yml
  translations:
    edit:
      heading: "AI translation"
      translate: "Translate"
      translate_multiple: "Translate into several languages…"
    show:
      heading: "Translating “%{game}”"
      progress: "%{done} of %{total}"
      model: "Model"
      locales: "Languages"
      tokens: "Tokens"
      token_counts: "input %{input}, output %{output}, from cache %{cached}"
      failed: "Not translated"
      cancel: "Stop"
      review: "Review the translation"
      state:
        pending: "Waiting"
        running: "Running"
        succeeded: "Finished"
        failed: "Failed"
        cancelled: "Stopped"
    review:
      heading: "Reviewing the translation of “%{game}”"
      accept_all: "Accept everything unflagged"
      accept: "Accept"
      reject: "Reject"
      state:
        pending: "Waiting"
        accepted: "Accepted"
        rejected: "Rejected"
    flags:
      empty: "Empty translation"
      identical: "Identical to the source — possibly untranslated"
      lost_digits: "A code or number was lost"
      lost_latin: "A Latin-script word or link was lost"
      length: "Implausible length"
```

- [ ] **Step 6: Run the view and i18n specs**

```bash
bundle exec rspec spec/requests/translation_views_spec.rb spec/i18n_spec.rb spec/i18n_play_screen_spec.rb
```

Expected: PASS. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity — if it fails, a key exists in one file and not the other.

- [ ] **Step 7: Commit**

```bash
git add app/views config/locales spec/requests/translation_views_spec.rb
git commit -m "Add the translation trigger, progress and review screens"
```

---

## Task 10: Stale-run sweep, deployment wiring and documentation

**Files:**
- Modify: `app/models/translation_run.rb`
- Modify: `app/controllers/translation_runs_controller.rb`
- Modify: `.kamal/secrets`
- Modify: `config/deploy.yml`
- Modify: `CLAUDE.md`
- Test: `spec/models/translation_run_sweep_spec.rb`

**Interfaces:**
- Consumes: `TranslationRun` (Task 1).
- Produces: `TranslationRun.sweep_stale!(older_than: 15.minutes)` → `Integer` (number of runs failed).

- [ ] **Step 1: Write the failing spec**

Create `spec/models/translation_run_sweep_spec.rb`:

```ruby
require "rails_helper"

describe TranslationRun, ".sweep_stale!" do
  let(:game)  { create_game }
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }

  def run_with(state, updated_at)
    run = TranslationRun.create!(:game => game, :actor => actor,
                                 :model => "claude-opus-5", :state => state)
    run.update_column(:updated_at, updated_at)
    run
  end

  # A thread killed by a deploy leaves its run in `running` forever, and
  # `one active run per game` then locks the game out of translation
  # permanently. The sweep is what stops a deploy from being a trap.
  it "fails a run that has made no progress for too long" do
    stale = run_with(TranslationRun::RUNNING, 30.minutes.ago)

    expect(TranslationRun.sweep_stale!).to eq(1)
    expect(stale.reload.state).to eq(TranslationRun::FAILED)
    expect(stale.error_message).to be_present
  end

  it "leaves a run that is still making progress alone" do
    fresh = run_with(TranslationRun::RUNNING, 1.minute.ago)

    expect(TranslationRun.sweep_stale!).to eq(0)
    expect(fresh.reload.state).to eq(TranslationRun::RUNNING)
  end

  it "leaves terminal runs alone however old they are" do
    done = run_with(TranslationRun::SUCCEEDED, 1.year.ago)

    TranslationRun.sweep_stale!
    expect(done.reload.state).to eq(TranslationRun::SUCCEEDED)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/models/translation_run_sweep_spec.rb
```

Expected: FAIL with `undefined method 'sweep_stale!'`.

- [ ] **Step 3: Implement the sweep and call it**

Add to `app/models/translation_run.rb`:

```ruby
  STALE_AFTER = 15.minutes

  # A thread killed mid-run -- by a deploy, an OOM, a restart -- leaves its row
  # in `running` forever, and the one-active-run-per-game rule then locks the
  # game out of translation permanently. Called opportunistically from the
  # controller rather than from a scheduler, because this application has no
  # scheduler and adding one for this would cost more than it saves.
  def self.sweep_stale!(older_than: STALE_AFTER)
    where(:state => ACTIVE_STATES)
      .where("updated_at < ?", older_than.ago)
      .update_all(:state => FAILED,
                  :error_message => "abandoned: no progress for #{older_than.inspect}",
                  :finished_at => Time.now,
                  :updated_at => Time.now)
  end
```

In `app/controllers/translation_runs_controller.rb`, add the sweep as a `before_action` after `load_game`:

```ruby
  before_action :sweep_stale_runs
```

and the private method:

```ruby
  # Opportunistic, not scheduled. The only moment a stale run actually matters
  # is when someone tries to start a new one, so that is where it is cleared.
  def sweep_stale_runs
    TranslationRun.sweep_stale!
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

```bash
bundle exec rspec spec/models/translation_run_sweep_spec.rb spec/requests/translation_runs_spec.rb
```

Expected: PASS.

- [ ] **Step 5: Wire the secret into the deployment**

In `.kamal/secrets`, after `KAMAL_REGISTRY_PASSWORD`:

```bash
# Claude API key for superadmin-triggered translation of game content.
# In CI this is a GitHub Actions secret; locally, export it. Never a literal
# here. With this unset the feature is simply absent -- no buttons, no routes
# reachable -- so development and CI need no key at all.
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
```

In `config/deploy.yml`, add to `env.secret`:

```yaml
    - ANTHROPIC_API_KEY
```

- [ ] **Step 6: Verify the production environment still boots**

Neither suite evaluates `config/environments/production.rb`, so boot it directly:

```bash
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com \
SMTP_USERNAME=u SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com \
DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'
```

Expected: `ok`. This proves the new gem and services load in production without `ANTHROPIC_API_KEY` set.

- [ ] **Step 7: Document the feature in CLAUDE.md**

Add a section after **Known, deliberate wart: `GET /logout`**:

```markdown
## AI translation of game content

A superadmin can translate a game's author-written content via the Claude API
(`app/services/translation/`, `TranslationRunsController`,
`TranslationProposalsController`). Four things about it are non-obvious:

- **It is staged.** The runner writes `translation_proposals`, never
  `content_translations`. Accepting a proposal goes through
  `TranslatableContent#translations_attributes=` — the same setter the
  authoring form uses — so the stored row is byte-identical to a hand-typed
  one and the game cannot tell the difference. Provenance lives only in
  `translation_proposals`.
- **The loop order is cost-critical: units outer, locales inner.** Prompt
  caching is a strict prefix match and the prompt is
  `[rules][this unit's source][translate into X]`. Holding the unit still
  while the locales vary means every locale after the first reads a cached
  prefix. Reversing the loops makes every call a cache miss. The locale calls
  must also stay sequential — a cache entry is only readable once the first
  response begins streaming. `spec/services/translation/runner_spec.rb` pins
  the order.
- **`Translation::Flags` is the safety story, not a nicety.** A superadmin
  reviewing Polish cannot evaluate Polish. Five mechanical checks —
  `empty`, `identical`, `lost_digits`, `lost_latin`, `length` — catch what
  they can still act on. `identical` guards the exact failure documented in
  `TranslatableContent#translation_draft`: text saved unchanged into another
  language's slot, which then satisfies the publish gate.
- **The run is a bare `Thread`, wrapped in `Rails.application.executor.wrap`.**
  There is no ActiveJob backend here and the host has one vCPU. The wrap is
  load-bearing: an unwrapped thread leaks a connection from the pool.
  `TranslationRun.sweep_stale!` exists because a thread killed by a deploy
  would otherwise leave the game locked out of translation forever.

`ANTHROPIC_API_KEY` is an env var via the Kamal secret, not Azure Key Vault —
Kamal 2.12 ships no Azure adapter, so Key Vault would mean a custom adapter or
an entrypoint shim, and a new boot-time failure mode for the whole app, for one
key. With the variable unset the feature is entirely absent, so development and
CI need no credential. See
`docs/superpowers/specs/2026-08-16-ai-translation-design.md`.
```

- [ ] **Step 8: Run both full gates — orchestrator only, never a subagent**

```bash
bundle exec rspec 2>&1 | tail -5
bundle exec cucumber 2>&1 | tail -5
```

Expected: RSpec `0 failures`, with the example count risen by roughly 50 from the Task 0 baseline. Cucumber **238 scenarios / 2386 steps**, unchanged — this plan adds no feature file, and counts cannot move unless a `.feature` file changed.

- [ ] **Step 9: Commit**

```bash
git add app/models/translation_run.rb app/controllers/translation_runs_controller.rb .kamal/secrets config/deploy.yml CLAUDE.md spec/models/translation_run_sweep_spec.rb
git commit -m "Sweep abandoned runs, wire the API key, document the feature"
```

---

## Self-review notes

Checked against the spec, section by section:

| Spec section | Covered by |
|---|---|
| §1 Data model | Task 1 |
| §2 Work-list | Task 2 |
| §3 Claude integration, caching, code-preservation rule | Tasks 5 and 6 |
| §4 Runner, executor wrap, resumability, cancellation, stale sweep | Tasks 6, 7 and 10 |
| §5 UI, five flags, acceptance path | Tasks 4, 8 and 9 |
| §6 Access control, audit, cost guards, model Setting | Tasks 3, 7 and 8 |
| §7 Failure handling | Task 6 (per-unit failure), Task 5 (refusal before content) |
| §8 Testing | Every task; full gates in Task 10 |
| §9 Non-goals | Task 9 (meta refresh, with the reasoning in the template comment) and Task 10 (`CLAUDE.md`) |

**Template ownership, settled during the pre-flight scan:** a task that renders a template owns it. Task 7 renders `new.html.erb` (its authorization spec `GET`s the new action and expects 200), so Task 7 creates it along with the `translations.new.*` keys. Task 8 renders nothing — every one of its specs POSTs and asserts a redirect — so `translation_proposals/index.html.erb` belongs to Task 9, which is the first task to `GET` it. No placeholder templates are needed anywhere.

**One known soft spot the executor should watch:**

1. **The `anthropic` gem's exact Ruby binding** for `usage.cache_read_input_tokens` and the `system_:` keyword is taken from the SDK's documented Ruby surface. If `bundle install` resolves a version whose surface differs, fix `Translation::Client` — it is the only file that touches the SDK, which is the whole point of the seam — and leave every spec unchanged, since they all stub it.
