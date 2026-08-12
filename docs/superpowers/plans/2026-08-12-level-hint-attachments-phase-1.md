# Level and Hint Attachments — Phase 1 Implementation Plan (Foundation)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay the foundation for per-game file libraries — image processing available and proven, Active Storage wired in, `Setting` able to hold a list of strings, and the `GameFile` / `FileAttachment` models with their associations — with nothing user-visible yet.

**Architecture:** Two new tables (`game_files`, `file_attachments`) plus Active Storage's three. `GameFile` is the per-game library entry and owns the bytes through `has_one_attached :file`. `FileAttachment` is a polymorphic join to `Level` or `Hint`, deliberately mirroring `ContentTranslation`'s existing `belongs_to :translatable, polymorphic: true` shape. `Setting` gains a `string_value` column so an allowed-extensions list can live beside the existing integer rate limits.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, SQLite (dev/test) / PostgreSQL (production), Active Storage Disk service, libvips via `image_processing`, RSpec 3.13, `acts_as_list`.

**Spec:** `docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md` (§1, §6, §8, and the CI half of §7).

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Every command below assumes you have run:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit a `.feature` file.** Phase 1 adds none. The frozen suite must still report **232 scenarios / 2342 steps** at the end of every task.
- **Hash rockets.** This codebase writes `:key => value` including for symbol keys. Match the surrounding file rather than switching to `key:` syntax.
- **`create_user` takes no arguments.** It generates its own nickname and e-mail; passing a hash raises `ArgumentError`. Factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` — not FactoryBot; do not introduce FactoryBot.
- **RSpec's legacy `should` syntax is enabled** for ~140 ported assertions. New specs use `expect`.
- **Do not trust a quoted RSpec example count.** Re-run it. Cucumber's 232/2342 is the stable figure.
- **`config/application.rb` requires railties selectively** — there is no `rails/all`. Adding a framework means adding its railtie by hand.
- **ActiveSupport core extensions are not all loaded in an environment file.** `32.megabytes` raises `NoMethodError` on `Integer` inside `config/environments/*.rb`. Write the literal.
- **A new validator needs its message in all seven locales** (`ru en uk ka tr be pl`) or `raise_on_missing_translations` turns a correct validation into a confusing raise. Phase 1 adds validators whose messages are model-level; §Task 5 covers this.
- **`Rails.cache` is real and process-global** (`:memory_store`); `spec/rails_helper.rb` clears it before each example. Do not add caching that assumes otherwise.
- **Run `bin/rails db:test:prepare` after adding a migration**, same as any Rails app.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/20260812100000_create_active_storage_tables.active_storage.rb` | Active Storage's three tables (generated, not hand-written) |
| `db/migrate/20260812110000_add_string_value_to_settings.rb` | `settings.string_value`, nullable |
| `db/migrate/20260812120000_create_game_files.rb` | the per-game library table |
| `db/migrate/20260812130000_create_file_attachments.rb` | the polymorphic join table |
| `config/storage.yml` | Active Storage service definitions |
| `app/models/game_file.rb` | one uploaded file in one game's library; owns the bytes |
| `app/models/file_attachment.rb` | joins a `GameFile` to a `Level` or `Hint`, ordered, optionally locale-scoped |
| `spec/models/game_file_spec.rb` | |
| `spec/models/file_attachment_spec.rb` | |
| `spec/models/setting_spec.rb` | (may already exist — extend if so) |
| `spec/image_processing_spec.rb` | proves libvips is present and working; **raises**, never skips |

**Modified:**

| File | Change |
|---|---|
| `Gemfile` | add `image_processing` |
| `config/application.rb:3-8` | add `require "active_storage/engine"` |
| `config/environments/production.rb` | `active_storage.service`, `active_job.queue_adapter` |
| `config/environments/development.rb` | same |
| `config/environments/test.rb` | same |
| `Dockerfile:22` | `libvips42 libheif1` in the runtime stage |
| `.github/workflows/ci.yml` | libvips install step in the `rspec` job |
| `.github/workflows/images.yml` | libvips assertion in the `app-image` job (tag `encounter-engine:test`) |
| `app/models/setting.rb` | split registry into `INTEGER_DEFAULTS` / `STRING_DEFAULTS`, add `Setting.list` |
| `app/models/level.rb` | `has_many :file_attachments, :as => :attachable` |
| `app/models/hint.rb` | same |
| `spec/spec_helpers/fixtures_helper.rb` | `create_game_file` helper |

---

## Task 1: libvips available, and proven rather than assumed

**Files:**
- Modify: `Gemfile`
- Modify: `Dockerfile:22`
- Modify: `.github/workflows/ci.yml` (`rspec` job)
- Modify: `.github/workflows/images.yml` (`app-image` job)
- Test: `spec/image_processing_spec.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `require "image_processing/vips"` succeeds in dev, test, CI and the production image. Phase 2 depends on this.

**Why this is task 1 and why the test raises:** the RSpec job runs inside `container: ruby:3.3.12`, a Debian image with no libvips, and the `Dockerfile` runtime stage installs only `libpq5 curl tzdata`. This repository has already paid for the alternative once — `spec/views/countdown_spec.rb` guarded its Node examples with `skip(...)` and consequently reported *pending* in every CI run for weeks, which is indistinguishable from passing in a log. Mirror `spec/helpers/countdown_plural_spec.rb:22`, which raises.

- [ ] **Step 1: Write the failing test**

Create `spec/image_processing_spec.rb`:

```ruby
require "rails_helper"

# libvips is a SYSTEM library, not a gem, so it can be absent in an environment
# where `bundle install` succeeded — the ruby-vips gem installs fine and then
# fails to find libvips.so at load time. Uploads cannot work without it.
#
# This spec RAISES rather than skips. See spec/helpers/countdown_plural_spec.rb
# for the precedent and CLAUDE.md for why: examples that guard themselves with
# skip() report as pending in CI, which reads exactly like passing unless you
# count them.
describe "libvips" do
  it "loads and performs a real image operation" do
    begin
      require "image_processing/vips"
    rescue LoadError => e
      raise "libvips is unavailable in this environment (#{e.message}). " \
            "Install it: apt-get install -y libvips42 libheif1. " \
            "Do NOT convert this example to a skip."
    end

    # A real operation, not a version string: a version constant can be
    # present while the shared library is too old to actually run.
    image = Vips::Image.black(10, 20)

    expect(image.width).to eq(10)
    expect(image.height).to eq(20)
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/image_processing_spec.rb
```

Expected: FAIL — `cannot load such file -- image_processing/vips` (the gem is not in the Gemfile yet).

- [ ] **Step 3: Add the gem**

In `Gemfile`, after the `acts_as_list` line:

```ruby
# Image canonicalisation for game file uploads: HEIC→JPEG, metadata stripping,
# and the web/thumb variants. `require: false` deliberately — ruby-vips binds
# to the system libvips through FFI at require time, so an eager require would
# turn a missing system library into a failure to BOOT rather than a failure to
# upload. See spec/image_processing_spec.rb.
gem "image_processing", "~> 1.13", require: false
```

- [ ] **Step 4: Install and run the test again**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle install
bundle exec rspec spec/image_processing_spec.rb
```

Expected on a machine with libvips: PASS. Expected without it: FAIL with the message from Step 1 — which is the correct outcome, and means you should `sudo apt-get install -y libvips42 libheif1` and re-run.

- [ ] **Step 5: Add libvips to the production image**

In `Dockerfile`, the **runtime** stage (currently line 22), extend the package list:

```dockerfile
# libvips42/libheif1 are what canonicalise uploads (HEIC→JPEG, EXIF stripping,
# web/thumb variants). libheif1 is separate: libvips can be built without HEIC
# support, and a photo from any iPhone arrives as HEIC.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq5 curl tzdata libvips42 libheif1 && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 6: Add libvips to the RSpec CI job**

In `.github/workflows/ci.yml`, in the `rspec` job, immediately after the "Install node" step:

```yaml
      # Same reasoning as the node step above, same failure mode. This job runs
      # in container: ruby:3.3.12 — Debian with no libvips — and
      # spec/image_processing_spec.rb RAISES rather than skips when it is
      # missing, so removing this step turns the suite red rather than quietly
      # shedding coverage. Do not convert that spec to a skip to avoid needing
      # this step.
      - name: Install libvips (for the image-processing specs)
        run: |
          apt-get update -qq
          apt-get install --no-install-recommends -y libvips42 libheif1
```

- [ ] **Step 7: Assert libvips inside the built image**

In **`.github/workflows/images.yml`** (not `ci.yml`), in the `app-image` job, immediately after the existing `Prove the image actually serves` step. That job builds the image as `encounter-engine:test`. Neither test suite evaluates `config/environments/production.rb`, so this job is the only thing that would catch a runtime library missing from the image:

```yaml
      # The RSpec job proves libvips exists on a Debian ruby image with an
      # apt-get step; that says nothing about the image we actually ship.
      # `bundle exec`, not bare ruby: the entrypoint is overridden here, so
      # nothing else puts the bundle on the load path.
      - name: Prove libvips is in the image
        run: |
          docker run --rm --entrypoint bundle encounter-engine:test \
            exec ruby -e 'require "image_processing/vips"; \
              abort("libvips broken in image") unless Vips::Image.black(4, 4).width == 4; \
              puts "libvips ok"'
```

- [ ] **Step 8: Run the full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber --format progress
```

Expected: RSpec green with one more example than before. Cucumber **232 scenarios / 2342 steps**, unchanged.

- [ ] **Step 9: Commit**

```bash
git add Gemfile Gemfile.lock Dockerfile .github/workflows/ci.yml .github/workflows/images.yml spec/image_processing_spec.rb
git commit -m "Add libvips, and a spec that raises rather than skips without it

image_processing is required: false on purpose. ruby-vips binds to the system
libvips through FFI at require time, so an eager require turns a missing
system library into a failure to boot instead of a failure to upload.

The spec raises where it could skip. spec/views/countdown_spec.rb guarded its
node examples with skip() and reported pending in every CI run for weeks,
which reads exactly like passing. Both CI jobs install the library so the
raise means what it says."
```

---

## Task 2: Wire Active Storage

**Files:**
- Modify: `config/application.rb:3-8`
- Create: `config/storage.yml`
- Create: `db/migrate/*_create_active_storage_tables.active_storage.rb` (generated)
- Modify: `config/environments/{production,development,test}.rb`
- Test: `spec/models/active_storage_wiring_spec.rb`

**Interfaces:**
- Consumes: Task 1's libvips (variants in Phase 2 need it).
- Produces: `ActiveStorage::Blob`, `has_one_attached`, and a configured `:local` / `:test` service. Task 4's `GameFile` depends on this.

**A decision this task makes explicitly.** Active Storage's engine pulls in Active Job, which this app otherwise does not have — no `app/jobs`, no adapter, no `active_job/railtie`. Rails' default would be `:async`, an in-process thread pool that silently drops queued work when a container stops. Set `:inline` instead: it is deterministic, loses nothing on deploy, and is honest about the fact that there is no queue. The spec's invariant **I2** ("nothing in this feature may depend on a background job") is what makes `:inline` sufficient rather than a compromise.

- [ ] **Step 1: Write the failing test**

Create `spec/models/active_storage_wiring_spec.rb`:

```ruby
require "rails_helper"

# Active Storage arrives by an explicit railtie require, because
# config/application.rb requires railties one at a time rather than using
# rails/all. These examples fail loudly if that require is ever dropped —
# which would otherwise show up as a NameError deep inside an upload.
describe "Active Storage wiring" do
  it "defines the blob model" do
    expect(defined?(ActiveStorage::Blob)).to eq("constant")
  end

  it "has all three tables" do
    %w[active_storage_blobs active_storage_attachments active_storage_variant_records].each do |table|
      expect(ActiveRecord::Base.connection.table_exists?(table)).to be(true), "missing #{table}"
    end
  end

  it "runs jobs inline rather than on a queue that does not exist" do
    # :async would silently drop queued work when the container stops, and
    # this app has no durable queue. See the design's invariant I2.
    expect(ActiveJob::Base.queue_adapter_name).to eq("inline")
  end

  it "stores test uploads somewhere disposable" do
    expect(Rails.application.config.active_storage.service).to eq(:test)
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/active_storage_wiring_spec.rb
```

Expected: FAIL — `uninitialized constant ActiveStorage`.

- [ ] **Step 3: Require the railtie**

In `config/application.rb`, in the require block at lines 3–8, after `require "active_record/railtie"`:

```ruby
# Active Storage for game file libraries (see
# docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md).
# It pulls in Active Job, which this app has no other use for — the queue
# adapter is pinned to :inline in the environment files for that reason.
require "active_storage/engine"
```

- [ ] **Step 4: Write the storage configuration**

Create `config/storage.yml`:

```yaml
# Disk, not Azure, and not by preference — see the design's "Why not Azure
# Blob" section. ActiveStorage::Service::AzureStorageService is deprecated
# (removed in Rails 8.1) and its constructor requires storage_access_key:,
# a shared key config/deploy.yml deliberately does not have because the VM
# authenticates to that storage account with a managed identity.
#
# The service abstraction is what keeps that decision reversible: switching
# is this file plus a byte migration, not a rewrite.
test:
  service: Disk
  root: <%= Rails.root.join("tmp/storage") %>

local:
  service: Disk
  root: <%= Rails.root.join("storage") %>

# Mounted as a Docker volume by config/deploy.yml. Preferably its own
# partition: filling it must not be able to reach Postgres or the other
# tenants on this host.
production:
  service: Disk
  root: /rails/storage
```

- [ ] **Step 5: Configure the environments**

In `config/environments/test.rb`:

```ruby
  config.active_storage.service = :test
  # No queue exists in this application. :inline is deterministic and loses
  # nothing; :async would drop work when the process stops.
  config.active_job.queue_adapter = :inline
```

In `config/environments/development.rb`:

```ruby
  config.active_storage.service = :local
  config.active_job.queue_adapter = :inline
```

In `config/environments/production.rb`:

```ruby
  config.active_storage.service = :production
  config.active_job.queue_adapter = :inline
```

- [ ] **Step 6: Generate and apply the Active Storage migration**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails active_storage:install
bin/rails db:migrate
bin/rails db:test:prepare
```

Do not hand-edit the generated migration. Check that `db/schema.rb`'s version bumped and the three tables appear.

- [ ] **Step 7: Run the test to verify it passes**

```bash
bundle exec rspec spec/models/active_storage_wiring_spec.rb
```

Expected: PASS, 4 examples.

- [ ] **Step 8: Prove production still boots**

Neither suite evaluates `config/environments/production.rb`, and this task edited it:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com \
  SMTP_USERNAME=u SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com \
  DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'
```

Expected: `ok`. A `NoMethodError` here usually means an ActiveSupport core extension was used in an environment file — write the literal instead.

- [ ] **Step 9: Run the full suites and commit**

```bash
bundle exec rspec
bundle exec cucumber --format progress   # must still be 232 / 2342
bin/rails zeitwerk:check

git add config/application.rb config/storage.yml config/environments db/migrate db/schema.rb spec/models/active_storage_wiring_spec.rb
git commit -m "Wire Active Storage, on Disk, with an inline job adapter

Disk rather than Azure Blob is forced, not preferred: the built-in
AzureStorageService is deprecated (gone in Rails 8.1) and requires a shared
access key that config/deploy.yml deliberately does not have — the VM uses a
managed identity. The service abstraction keeps the swap cheap.

The engine drags in Active Job, which this app otherwise has no use for.
Pinned to :inline rather than Rails' :async default, which would silently drop
queued work when a container stops. Nothing in this feature may depend on a
job completing, so inline is sufficient rather than a compromise."
```

---

## Task 3: Let `Setting` hold a list of strings

**Files:**
- Create: `db/migrate/20260812110000_add_string_value_to_settings.rb`
- Modify: `app/models/setting.rb`
- Test: `spec/models/setting_spec.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `Setting.list(name) → Array<String>`, `Setting.put(name, value)` accepting a string or array for string keys, `Setting::INTEGER_DEFAULTS`, `Setting::STRING_DEFAULTS`. Phase 2's quota and extension checks consume these.

**The constraint being worked around:** `Setting` today validates `value` as `numericality: { only_integer: true }` unconditionally, and whitelists `name` against a single `DEFAULTS` hash. An allowed-extensions list is strings. The change must leave `Setting.integer` behaving exactly as it does now — `RequestThrottling` reads the four rate-limit keys through it on every throttled request.

**Pre-flight ruling (2026-08-12, repository owner): the registry is split three ways.** An earlier draft of this task folded the five storage keys straight into `DEFAULTS`. That breaks an existing passing spec: `Admin::SettingsController#current_values` (`settings_controller.rb:47`) iterates `Setting::DEFAULTS.keys`, the view labels each with `t("admin.settings.names.#{name}")` (`show.html.erb:8`), only four such labels exist (`ru.yml:94-98`), and `config/environments/test.rb:26` raises on missing translations — so `spec/requests/admin_settings_spec.rb:28` would go red. It also contradicted this plan's own "nothing user-visible has changed" exit criterion.

So: `DEFAULTS` stays **exactly the four rate-limit keys** and remains what the admin page renders. Storage keys are validated and readable by code but are **not** on the admin page in Phase 1. Phase 2 flips `DEFAULTS` to `INTEGER_DEFAULTS` and adds the five labels across all seven locales at the same time it adds the enforcement that makes them meaningful. **Do not add any `admin.settings.names.*` key in this task.**

- [ ] **Step 1: Write the failing test**

Add to `spec/models/setting_spec.rb` (create the file with `require "rails_helper"` if it does not exist):

```ruby
describe "string settings" do
  it "returns the shipped default when no row exists" do
    expect(Setting.list("allowed_extensions")).to eq(%w[jpg jpeg png gif heic pdf])
  end

  it "round-trips a list through the database" do
    Setting.put("allowed_extensions", %w[jpg pdf])

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
  end

  it "accepts a space-separated string, which is what the admin form submits" do
    Setting.put("allowed_extensions", "jpg  pdf\n png")

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf png])
  end

  it "lowercases and strips, so 'JPG ' and 'jpg' are one entry" do
    Setting.put("allowed_extensions", "JPG jpg  PDF ")

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
  end

  it "refuses a name that is not a registered string key" do
    expect { Setting.put("no_such_key", "x") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end

describe "the admin settings page's key list" do
  # The page iterates Setting::DEFAULTS.keys and labels each with
  # t("admin.settings.names.<key>"). Adding a key here without its label in all
  # seven locales makes that page raise under raise_on_missing_translations.
  # Phase 2 moves the storage keys in, with their labels, alongside the code
  # that enforces them.
  it "still offers exactly the four rate limits" do
    expect(Setting::DEFAULTS.keys).to eq(%w[signup_max signup_window_seconds reset_max reset_window_seconds])
  end

  it "does not yet offer the storage keys" do
    expect(Setting::DEFAULTS.keys & Setting::STORAGE_DEFAULTS.keys).to be_empty
  end

  it "still answers Setting.integer for a storage key even though the page hides it" do
    expect(Setting.integer("game_quota_megabytes")).to eq(100)
  end

  it "does not require a numeric value for a string key" do
    expect { Setting.put("allowed_extensions", "jpg") }.not_to raise_error
  end
end

describe "integer settings, unchanged" do
  it "still returns the shipped default" do
    expect(Setting.integer("signup_max")).to eq(5)
  end

  it "still round-trips" do
    Setting.put("signup_max", 9)

    expect(Setting.integer("signup_max")).to eq(9)
  end

  it "still rejects a non-integer value for an integer key" do
    expect { Setting.put("signup_max", "abc") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "still accepts zero, the documented off switch" do
    expect { Setting.put("signup_max", 0) }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/setting_spec.rb
```

Expected: FAIL — `undefined method 'list' for Setting`.

- [ ] **Step 3: Add the column**

Create `db/migrate/20260812110000_add_string_value_to_settings.rb`:

```ruby
# Settings held integers only -- the four rate limits. The allowed-extensions
# list for game file uploads is strings, and it belongs on the same admin page
# and in the same audit trail, so the table grows a second value column rather
# than the application growing a second settings mechanism.
#
# Nullable: an integer setting has no string_value and a string setting has no
# value, and which one is meaningful is decided by the key, not by the row.
class AddStringValueToSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :settings, :string_value, :string
    change_column_null :settings, :value, true
  end
end
```

- [ ] **Step 4: Rewrite the model**

Replace the body of `app/models/setting.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# Operator-tunable numbers that must be changeable without a deploy.
#
# Defaults live here rather than as seed rows so a fresh database, a restored
# one, and a test transaction all behave identically -- and so deleting a row
# is a safe way back to the shipped value.
class Setting < ApplicationRecord
  # Per client IP, per window. 0 disables the limit entirely -- see
  # RequestThrottling, which checks for it before touching the cache.
  RATE_LIMIT_DEFAULTS = {
    "signup_max"            => 5,
    "signup_window_seconds" => 3600,
    "reset_max"             => 3,
    "reset_window_seconds"  => 3600
  }.freeze

  # Game file storage. See
  # docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md §6.
  #
  # Deliberately NOT in DEFAULTS below, which is what the admin settings page
  # iterates: nothing enforces these until phase 2, and a settings screen
  # offering a quota that no code obeys is worse than no screen at all. Phase 2
  # points DEFAULTS at INTEGER_DEFAULTS and adds the five
  # admin.settings.names.* labels across all seven locales in the same change
  # that adds the enforcement.
  STORAGE_DEFAULTS = {
    "file_max_megabytes"         => 25,
    "max_files_per_upload"       => 10,
    "game_quota_megabytes"       => 100,
    "instance_cap_megabytes"     => 4096,
    "free_space_floor_megabytes" => 2048
  }.freeze

  # Every integer key that Setting.integer will answer for and that the
  # numericality validation applies to.
  INTEGER_DEFAULTS = RATE_LIMIT_DEFAULTS.merge(STORAGE_DEFAULTS).freeze

  # List-of-strings keys. Stored space-separated in string_value.
  #
  # allowed_extensions is NOT the last word on what may be uploaded: it is
  # intersected with a hard-coded constant before use, so a superadmin can
  # narrow the set but cannot widen it to something that executes (svg, html).
  # See the design's §4.
  STRING_DEFAULTS = {
    "allowed_extensions" => %w[jpg jpeg png gif heic pdf]
  }.freeze

  # What the admin settings page renders -- unchanged, four keys. See the
  # pre-flight ruling in this task's plan text.
  DEFAULTS = RATE_LIMIT_DEFAULTS

  validates :name, :presence => true, :uniqueness => true,
                   :inclusion => { :in => INTEGER_DEFAULTS.keys + STRING_DEFAULTS.keys }

  # Conditional now, unconditional before: a string key legitimately has a nil
  # `value`. greater_than_or_equal_to, not greater_than -- zero is the
  # documented "off" switch and an operator will reach for it during an
  # incident.
  validates :value, :numericality => { :only_integer => true,
                                       :greater_than_or_equal_to => 0 },
                    :if => :integer_key?

  def self.integer(name)
    find_by(:name => name)&.value || INTEGER_DEFAULTS.fetch(name)
  end

  def self.list(name)
    record = find_by(:name => name)
    return STRING_DEFAULTS.fetch(name) if record.nil? || record.string_value.nil?

    normalise_list(record.string_value)
  end

  def self.put(name, value)
    record = find_or_initialize_by(:name => name)

    if STRING_DEFAULTS.key?(name)
      record.string_value = normalise_list(value).join(" ")
    else
      record.value = value
    end

    record.save!
    record
  end

  # "JPG  pdf\n png" and %w[JPG pdf png] both become %w[jpg pdf png].
  # Split on any whitespace or comma: the admin form is a free-text field and
  # an operator will separate with whichever of the two they think of first.
  def self.normalise_list(value)
    Array(value).join(" ").downcase.split(/[\s,]+/).reject(&:empty?).uniq
  end

  private

  def integer_key?
    INTEGER_DEFAULTS.key?(name)
  end
end
```

- [ ] **Step 5: Migrate and run the test**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
bundle exec rspec spec/models/setting_spec.rb
```

Expected: PASS, 13 examples.

- [ ] **Step 6: Prove the rate limiter is untouched**

`RequestThrottling` reads these on every throttled request, and the signup Cucumber scenarios drive it:

```bash
bundle exec rspec spec/controllers spec/models
bundle exec cucumber features/signup features/teams --format progress
```

Expected: green. If `features/signup` fails, check that `Setting.integer` still returns the default when no row exists — that is the path the throttler takes on a fresh database.

- [ ] **Step 7: Run the full suites and commit**

```bash
bundle exec rspec
bundle exec cucumber --format progress   # 232 / 2342

git add db/migrate db/schema.rb app/models/setting.rb spec/models/setting_spec.rb
git commit -m "Let Setting hold a list of strings, not only integers

The allowed-extensions list for file uploads belongs on the same admin page
and in the same audit trail as the rate limits, so the table grows a second
value column rather than the app growing a second settings mechanism.

Setting.integer keeps its exact behaviour -- RequestThrottling reads four keys
through it on every throttled request. The one existing behaviour that changed
is that numericality is now conditional on the key being an integer key, since
a string key legitimately has a nil value; four examples pin the old behaviour
so that change cannot drift."
```

---

## Task 4: The `GameFile` model

**Files:**
- Create: `db/migrate/20260812120000_create_game_files.rb`
- Create: `app/models/game_file.rb`
- Modify: `spec/spec_helpers/fixtures_helper.rb`
- Test: `spec/models/game_file_spec.rb`

**Blocked-task ruling (2026-08-12, repository owner).** An earlier draft of this task declared `has_many :file_attachments, :dependent => :destroy` on `GameFile`. That cannot work here: `:dependent => :destroy` resolves its target class **eagerly on destroy**, not lazily and not only when child rows exist, so `GameFile#destroy` raised `NameError: Missing model class FileAttachment for the GameFile#file_attachments association` — failing this task's own last example, "is destroyed with its game". Reproduced directly: 9 examples, 1 failure.

**The association moves to Task 5**, which creates `FileAttachment` and already carries the spec that covers the cascade (`"is destroyed with its game_file"`). Nothing is lost — the cascade still ships in Phase 1, one task later. **Do not declare `has_many :file_attachments` in this task, and do not create a stub `FileAttachment` class** — Task 5 owns it.

This task's "is destroyed with its game" example still passes without the association, because `Game` destroys its `game_files` regardless.

**Interfaces:**
- Consumes: Active Storage from Task 2.
- Produces:
  - `GameFile#total_byte_size → Integer` (`byte_size + derived_byte_size`)
  - `GameFile.storage_used_by(game) → Integer` (bytes, sum over the game)
  - `GameFile#file` — the Active Storage attachment
  - `create_game_file(:game => game) → GameFile` test helper
  - Task 5's `FileAttachment` belongs to this.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game_file_spec.rb`:

```ruby
require "rails_helper"

describe GameFile do
  before(:each) do
    @game = create_game
  end

  it "requires a game" do
    file = GameFile.new(:filename => "дом.jpg", :content_type => "image/jpeg")

    expect(file).not_to be_valid
    expect(file.errors[:game]).not_to be_empty
  end

  it "requires a filename" do
    file = GameFile.new(:game => @game, :content_type => "image/jpeg")

    expect(file).not_to be_valid
  end

  it "allows the same filename in two different games" do
    other = create_game
    create_game_file(:game => @game, :filename => "дом.jpg")

    expect(build_game_file(:game => other, :filename => "дом.jpg")).to be_valid
  end

  it "refuses a duplicate filename within one game" do
    create_game_file(:game => @game, :filename => "дом.jpg")

    duplicate = build_game_file(:game => @game, :filename => "дом.jpg")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:filename]).not_to be_empty
  end

  describe "storage accounting" do
    it "counts the canonical bytes AND the derived variants" do
      # A 5 MB original yielding a 240 KB web and an 18 KB thumb occupies all
      # three on disk, so all three count against the quota.
      file = create_game_file(:game => @game, :byte_size => 5_000_000,
                                              :derived_byte_size => 258_000)

      expect(file.total_byte_size).to eq(5_258_000)
    end

    it "sums a game's whole library" do
      create_game_file(:game => @game, :byte_size => 1_000, :derived_byte_size => 100)
      create_game_file(:game => @game, :byte_size => 2_000, :derived_byte_size => 200)

      expect(GameFile.storage_used_by(@game)).to eq(3_300)
    end

    it "reports zero for a game with no files rather than nil" do
      expect(GameFile.storage_used_by(create_game)).to eq(0)
    end

    it "does not count another game's files" do
      create_game_file(:game => create_game, :byte_size => 9_999_999)

      expect(GameFile.storage_used_by(@game)).to eq(0)
    end
  end

  it "is destroyed with its game" do
    create_game_file(:game => @game)

    expect { @game.destroy }.to change { GameFile.count }.by(-1)
  end
end
```

- [ ] **Step 2: Add the test helpers**

In `spec/spec_helpers/fixtures_helper.rb`, after `create_game`:

```ruby
  def build_game_file(options={})
    params = {
      :game              => options[:game] || create_game,
      :filename          => "file#{random_string}.jpg",
      :content_type      => "image/jpeg",
      :byte_size         => 1024,
      :derived_byte_size => 0
    }.merge(options)
    GameFile.new params
  end

  def create_game_file(options={})
    game_file = build_game_file(options)
    game_file.save!
    game_file
  end
```

- [ ] **Step 3: Run it to make sure it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game_file_spec.rb
```

Expected: FAIL — `uninitialized constant GameFile`.

- [ ] **Step 4: Write the migration**

Create `db/migrate/20260812120000_create_game_files.rb`:

```ruby
# One uploaded file in one game's library. A Game is the CONTENT, so its files
# are content too: every run of the game shows the same photos, which is why
# this hangs off game_id and not game_run_id.
#
# See docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md §1.
class CreateGameFiles < ActiveRecord::Migration[8.0]
  def change
    create_table :game_files do |t|
      t.integer :game_id, :null => false
      # The name the AUTHOR sees. Never a path: Active Storage names the bytes
      # on disk by opaque key, so "../../etc/passwd" here is inert.
      t.string  :filename, :null => false
      # Sniffed from the file's own leading bytes, never taken from the
      # request header or the extension -- both are attacker-controlled.
      t.string  :content_type, :null => false
      # Size AFTER canonicalisation, not as uploaded: a 4 MB HEIC becomes a
      # 1.1 MB JPEG and it is the JPEG that occupies the disk.
      t.integer :byte_size, :null => false, :default => 0
      # Sum of the generated web/thumb variants. Counted against the quota
      # because they are equally real on the disk.
      t.integer :derived_byte_size, :null => false, :default => 0
      t.string  :checksum
      t.integer :uploaded_by_id
      t.timestamps
    end

    add_index :game_files, :game_id
    # Unique per game, not globally: two games may each have their own дом.jpg.
    add_index :game_files, [ :game_id, :filename ], :unique => true
  end
end
```

- [ ] **Step 5: Write the model**

Create `app/models/game_file.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# One file in one game's library.
#
# The library is per GAME, not per game-run: levels and hints hang off Game,
# and a GameRun is "one event over that content", so run-scoped files would
# make photographs the only per-run content in the system.
class GameFile < ApplicationRecord
  # optional: true plus an explicit presence validation -- the established
  # shape in this codebase (see Game#author, GameRun#game).
  belongs_to :game, :optional => true
  belongs_to :uploaded_by, :class_name => "User", :optional => true

  # NOTE: `has_many :file_attachments, :dependent => :destroy` deliberately
  # does NOT live here yet -- Task 5 adds it, in the same commit that creates
  # FileAttachment. See the ruling in this task's plan text.

  # The canonical bytes. Variants are generated eagerly at upload rather than
  # on first request, so that reading never allocates disk -- see the design's
  # invariant I1.
  has_one_attached :file

  validates :game, :presence => true
  validates :filename, :presence => true,
                       :uniqueness => { :scope => :game_id }
  validates :content_type, :presence => true

  scope :of_game, ->(game) { where(:game_id => game) }

  # What this file actually occupies: the canonical bytes AND the variants
  # derived from them. Quota arithmetic must use this, never byte_size alone.
  def total_byte_size
    byte_size.to_i + derived_byte_size.to_i
  end

  # Bytes used by one game's whole library. Returns 0, never nil, for a game
  # with no files -- callers compare it against a quota.
  def self.storage_used_by(game)
    of_game(game).sum(:byte_size) + of_game(game).sum(:derived_byte_size)
  end
end
```

Two sums rather than `sum("byte_size + derived_byte_size")`: a SQL string expression is one more place SQLite and PostgreSQL could disagree, and this codebase has already been bitten by that (see the correlated subquery in `20260810200000_drop_run_columns_from_games.rb`).

- [ ] **Step 6: Declare the association on `Game`**

In `app/models/game.rb`, beside the other `has_many` declarations:

```ruby
  has_many :game_files, :dependent => :destroy
```

- [ ] **Step 7: Migrate and run the test**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
bundle exec rspec spec/models/game_file_spec.rb
```

Expected: PASS, 9 examples.

- [ ] **Step 8: Run the full suites and commit**

```bash
bundle exec rspec
bundle exec cucumber --format progress   # 232 / 2342
bin/rails zeitwerk:check

git add db/migrate db/schema.rb app/models/game_file.rb app/models/game.rb spec/models/game_file_spec.rb spec/spec_helpers/fixtures_helper.rb
git commit -m "Add GameFile, the per-game file library

Per game rather than per game-run: levels and hints hang off Game, and a
GameRun is one event over that content, so run-scoped files would make
photographs the only per-run content in the system.

storage_used_by sums byte_size AND derived_byte_size, because generated
variants occupy the disk exactly as much as the canonical bytes do. Two
separate sums rather than one SQL expression -- SQLite and PostgreSQL have
already disagreed about expression syntax once in this codebase."
```

---

## Task 5: The `FileAttachment` join, and Level/Hint associations

**Files:**
- Create: `db/migrate/20260812130000_create_file_attachments.rb`
- Create: `app/models/file_attachment.rb`
- Modify: `app/models/level.rb`, `app/models/hint.rb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/models/file_attachment_spec.rb`

**Interfaces:**
- Consumes: `GameFile` from Task 4.
- Produces:
  - `FileAttachment.for_locale(locale) → Relation` (rows with `locale IS NULL OR locale = ?`)
  - `Level#file_attachments`, `Hint#file_attachments`, both ordered by `position`
  - `Level#game_files`, `Hint#game_files`
  - Phase 3's picker and play-screen rendering consume these.

- [ ] **Step 1: Write the failing test**

Create `spec/models/file_attachment_spec.rb`:

```ruby
require "rails_helper"

describe FileAttachment do
  before(:each) do
    @game  = create_game
    @level = create_level(:game => @game)
    @file  = create_game_file(:game => @game)
  end

  it "attaches a file to a level" do
    attachment = FileAttachment.create!(:game_file => @file, :attachable => @level)

    expect(@level.reload.file_attachments).to eq([attachment])
    expect(@level.game_files).to eq([@file])
  end

  it "attaches a file to a hint" do
    hint = Hint.create!(:level => @level, :text => "подсказка", :delay => 60)
    attachment = FileAttachment.create!(:game_file => @file, :attachable => hint)

    expect(hint.reload.file_attachments).to eq([attachment])
  end

  it "refuses a file from a different game" do
    # Otherwise an author could attach another game's photo, and the serving
    # controller's authorization is scoped by game -- the attachment would
    # exist and the image would 404 for every player.
    foreign = create_game_file(:game => create_game)

    attachment = FileAttachment.new(:game_file => foreign, :attachable => @level)

    expect(attachment).not_to be_valid
    expect(attachment.errors[:game_file]).not_to be_empty
  end

  it "requires a game_file" do
    expect(FileAttachment.new(:attachable => @level)).not_to be_valid
  end

  it "requires something to attach to" do
    expect(FileAttachment.new(:game_file => @file)).not_to be_valid
  end

  describe "locale scoping" do
    it "defaults to NULL, meaning every language" do
      attachment = FileAttachment.create!(:game_file => @file, :attachable => @level)

      expect(attachment.locale).to be_nil
    end

    it "includes NULL rows for every locale" do
      neutral = FileAttachment.create!(:game_file => @file, :attachable => @level)

      expect(FileAttachment.for_locale("en")).to include(neutral)
      expect(FileAttachment.for_locale("ru")).to include(neutral)
    end

    it "includes a locale-specific row only for its own locale" do
      english = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                       :attachable => @level, :locale => "en")

      expect(FileAttachment.for_locale("en")).to include(english)
      expect(FileAttachment.for_locale("ru")).not_to include(english)
    end

    it "refuses a locale the application does not serve" do
      attachment = FileAttachment.new(:game_file => @file, :attachable => @level,
                                      :locale => "zz")

      expect(attachment).not_to be_valid
    end
  end

  describe "ordering" do
    it "numbers attachments from 1 in the order they are added" do
      first  = FileAttachment.create!(:game_file => @file, :attachable => @level)
      second = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                      :attachable => @level)

      expect([ first.reload.position, second.reload.position ]).to eq([ 1, 2 ])
    end

    it "numbers each level's list independently" do
      other_level = create_level(:game => @game)
      FileAttachment.create!(:game_file => @file, :attachable => @level)
      elsewhere = FileAttachment.create!(:game_file => create_game_file(:game => @game),
                                         :attachable => other_level)

      expect(elsewhere.reload.position).to eq(1)
    end
  end

  it "is destroyed with its level, leaving the library file alone" do
    FileAttachment.create!(:game_file => @file, :attachable => @level)

    expect { @level.destroy }.to change { FileAttachment.count }.by(-1)
    expect(GameFile.exists?(@file.id)).to be(true)
  end

  it "is destroyed with its game_file" do
    FileAttachment.create!(:game_file => @file, :attachable => @level)

    expect { @file.destroy }.to change { FileAttachment.count }.by(-1)
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/file_attachment_spec.rb
```

Expected: FAIL — `uninitialized constant FileAttachment`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260812130000_create_file_attachments.rb`:

```ruby
# What a game file is attached to.
#
# Polymorphic on purpose: it mirrors ContentTranslation's
# `belongs_to :translatable, polymorphic: true`, so levels and hints share one
# association and a third owner later costs nothing.
class CreateFileAttachments < ActiveRecord::Migration[8.0]
  def change
    create_table :file_attachments do |t|
      t.integer :game_file_id, :null => false
      t.string  :attachable_type, :null => false
      t.integer :attachable_id, :null => false
      # NULL means "show in every language", which is what every file gets by
      # default -- a photograph of a building has no language. A non-null
      # value scopes the attachment to one locale, for the rare case of a map
      # whose labels are translated.
      t.string  :locale
      t.integer :position
      t.timestamps
    end

    add_index :file_attachments, [ :attachable_type, :attachable_id ]
    add_index :file_attachments, :game_file_id
  end
end
```

- [ ] **Step 4: Write the model**

Create `app/models/file_attachment.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# Joins a GameFile to the Level or Hint that displays it.
class FileAttachment < ApplicationRecord
  belongs_to :game_file, :optional => true
  belongs_to :attachable, :polymorphic => true, :optional => true

  # Scoped to the owner AND the locale: a level's language-neutral list and
  # its English-only list are two independently ordered strips, not one list
  # with gaps.
  acts_as_list :scope => [ :attachable_type, :attachable_id, :locale ]

  validates :game_file, :presence => true
  validates :attachable, :presence => true
  validate  :locale_is_served
  validate  :file_belongs_to_the_same_game

  # Rows a player in `locale` should see: the language-neutral ones plus the
  # ones for their language. Written as an explicit NULL check rather than
  # where(:locale => [nil, locale]) so the intent survives a later edit.
  scope :for_locale, ->(locale) {
    where("locale IS NULL OR locale = ?", locale.to_s)
  }

  private

  def locale_is_served
    return if locale.blank?
    return if I18n.available_locales.map(&:to_s).include?(locale)

    errors.add(:locale, :inclusion)
  end

  # An author can only attach files from the game they are editing. Without
  # this the row would save and then serve nothing: the delivery controller
  # authorises by game, so a foreign file 404s for every player while looking
  # perfectly attached in the editor.
  def file_belongs_to_the_same_game
    return if game_file.nil? || attachable.nil?

    owning_game = case attachable
                  when Level then attachable.game
                  when Hint  then attachable.level&.game
                  end

    return if owning_game.nil? || owning_game == game_file.game

    errors.add(:game_file, :inclusion)
  end
end
```

- [ ] **Step 5: Declare the associations on `GameFile`, `Level` and `Hint`**

`GameFile` gets the association Task 4 deliberately left out, now that `FileAttachment` exists. In `app/models/game_file.rb`, replace the placeholder comment (`# NOTE: has_many :file_attachments ... Task 5 adds it`) with the real declaration, immediately after the two `belongs_to` lines:

```ruby
  has_many :file_attachments, :dependent => :destroy
```

Destroying a library file destroys the rows that attach it to levels and hints. This is what makes this task's last example — `"is destroyed with its game_file"` — pass; without it that example fails, and `GameFile#destroy` would leave orphaned `file_attachments` rows pointing at a file that no longer exists.

In `app/models/level.rb`, beside the existing `has_many :hints`:

```ruby
  has_many :file_attachments, -> { order(:position) },
           :as => :attachable, :dependent => :destroy
  has_many :game_files, :through => :file_attachments
```

In `app/models/hint.rb`, after `belongs_to :level`:

```ruby
  has_many :file_attachments, -> { order(:position) },
           :as => :attachable, :dependent => :destroy
  has_many :game_files, :through => :file_attachments
```

- [ ] **Step 6: Add the validation messages to all seven locales**

`errors.add(:locale, :inclusion)` and `errors.add(:game_file, :inclusion)` resolve through Rails' `:inclusion` key, which `rails-i18n` supplies for all seven locales — so no new key is strictly required. Confirm rather than assume:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/file_attachment_spec.rb
```

`raise_on_missing_translations` is on in test, so a missing message fails here rather than in production. If it *does* raise, add `activerecord.errors.models.file_attachment.attributes.<attr>.inclusion` to **all seven** files in `config/locales/`, and check `spec/i18n_spec.rb` still passes (it enforces exact `ru`↔`en` parity).

- [ ] **Step 7: Migrate and run the test**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:migrate
bin/rails db:test:prepare
bundle exec rspec spec/models/file_attachment_spec.rb
```

Expected: PASS, 13 examples.

If the two ordering examples fail, the cause is `acts_as_list` with a nullable column in its scope — it builds `locale = NULL` rather than `locale IS NULL` in some versions. Fix by giving the scope a lambda instead:

```ruby
  acts_as_list :scope => ->(attachment) {
    where(:attachable_type => attachment.attachable_type,
          :attachable_id   => attachment.attachable_id,
          :locale          => attachment.locale)
  }
```

- [ ] **Step 8: Run the full suites and commit**

```bash
bundle exec rspec
bundle exec cucumber --format progress   # 232 / 2342
bin/rails zeitwerk:check

git add db/migrate db/schema.rb app/models/file_attachment.rb app/models/level.rb app/models/hint.rb spec/models/file_attachment_spec.rb config/locales
git commit -m "Add FileAttachment, joining game files to levels and hints

Polymorphic, mirroring ContentTranslation's translatable: levels and hints
share one association and a third owner later costs nothing.

locale is nullable and NULL means every language, which is what a photograph
of a building is. The rare translated map gets a locale-scoped row, and
for_locale returns both.

file_belongs_to_the_same_game is not defensive tidiness: the delivery
controller authorises by game, so an attachment pointing at another game's
file would save cleanly, look attached in the editor, and 404 for every
player."
```

---

## Phase 1 exit criteria

- [ ] `bundle exec rspec` green.
- [ ] `bundle exec cucumber --format progress` reports **232 scenarios / 2342 steps**, unchanged.
- [ ] `bin/rails zeitwerk:check` clean.
- [ ] The production boot probe from Task 2 Step 8 prints `ok`.
- [ ] CI green on all four jobs, including the new libvips steps.
- [ ] Nothing user-visible has changed. No route, controller or view was touched.

---

## Self-review notes

**Spec coverage.** Phase 1 covers §1 (data model, both tables, the Active Storage cost and its `:inline` mitigation), §6 (the `Setting` string extension and every new key's default), and §8's gem, railtie, Dockerfile and CI items. §2 (upload pipeline), §3 (disk protection), §4 (serving and authorization), §5 (Explorer and picker), §7a phases 2–4 and the `azcopy` backup are **deliberately out of scope for this plan** and belong to the phase plans that follow.

**Deliberately deferred, and where each one lands:**

| Deferred | Lands in |
|---|---|
| `PERMITTED` constant intersecting `allowed_extensions` | Phase 2 (it belongs with the validator that reads it) |
| The five storage keys appearing on `/admin/settings`, with labels in seven locales | Phase 2 (pre-flight ruling: added with the enforcement, not before it) |
| Magic-byte sniffing, HEIC→JPEG, EXIF stripping, variants | Phase 2 |
| Quota enforcement, the row lock, the `statvfs` floor, `max_request_body` | Phase 2 |
| Explorer page, upload form | Phase 2 |
| Picker, play-screen strip, delivery controller, the §4 authorization matrix | Phase 3 |
| Reclaim tooling, dashboard usage, `azcopy sync` | Phase 4 |
| The new Russian `.feature` files | Phase 2 (Explorer) and Phase 3 (attach/play) |

**Open inputs from spec §9 that Phase 1 does not need.** `instance_cap_megabytes` ships with a placeholder default of 4096 in Task 3 because nothing reads it until Phase 2; a fresh `df -h` must set it before Phase 2 enforces anything. The separate-partition question affects `config/deploy.yml` in Phase 2. The `azure-blob` investigation affects `config/storage.yml`, which Task 2 writes in the reversible form that makes the swap cheap.
