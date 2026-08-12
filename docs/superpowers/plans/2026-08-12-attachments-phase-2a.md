# Attachments Phase 2A — settings, upload pipeline, disk protection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make uploads safe and bounded at the model level — every byte sniffed, canonicalised and metadata-stripped before storage, and every write refused unless it fits inside the game quota, the instance cap and the free-space floor.

**Architecture:** One PORO, `GameFileUpload`, owns the whole ingest path and is the single place that sets `GameFile`'s four denormalised fields. `DiskSpace` wraps the free-space probe so it can be stubbed. `Setting`'s storage keys reach the admin page for the first time, with their labels in all seven locales. Nothing user-facing beyond the settings screen; the Explorer page and reclaim tooling are Phase 2B.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, Active Storage Disk service, libvips via `image_processing`, Marcel 1.2.1 (already bundled via Active Storage), RSpec 3.13.

**Spec:** `docs/superpowers/specs/2026-08-12-attachments-phase-2-design.md` — §1 (disk protection), §2 (upload pipeline), §3 (settings half), §4 (ledger), §6 units 1–3.

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix commands with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **libvips may need `LD_LIBRARY_PATH` on a hand-installed host.** A normal `apt-get install libvips42 libheif1` needs nothing. If `spec/image_processing_spec.rb` raises, install the packages rather than skipping it.
- **Never edit a `.feature` file.** This plan adds none. The **232 inherited scenarios** must still pass; Cucumber must still report **232 scenarios / 2342 steps** at the end of every task.
- **Hash rockets** (`:key => value`), including for symbol keys. Match the surrounding file.
- **`create_user` takes no arguments.** Fixtures are plain helpers in `spec/spec_helpers/fixtures_helper.rb`. **No FactoryBot.**
- **A new user-facing string needs all seven locales** (`ru en uk ka tr be pl`); the test environment sets `raise_on_missing_translations = true`. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and requires the other five to be a subset.
- **Turkish rule:** a key interpolating a user-authored value must put the case suffix on a common noun, never on the placeholder.
- **No new gems.** Marcel and `image_processing` are already bundled. Free-space probing shells out to `df` rather than adding `sys-filesystem`.
- **Run `bin/rails db:test:prepare` after adding a migration.**
- **Neither suite evaluates `config/environments/production.rb`.** Task 4 edits deploy config; the production boot probe is mandatory there.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `app/models/game_file_upload.rb` | the whole ingest path: sniff → validate → canonicalise → attach → variants → set fields |
| `app/models/disk_space.rb` | free-space probe, isolated so it can be stubbed |
| `spec/models/game_file_upload_spec.rb` | |
| `spec/models/disk_space_spec.rb` | |
| `spec/fixtures/files/` | real `.jpg`, `.png`, `.gif`, `.heic`, `.pdf`, plus a `.jpg`-named HTML file and a GPS-tagged JPEG |

**Modified:**

| File | Change |
|---|---|
| `.gitignore` | sqlite WAL sidecars (Task 1, its own commit) |
| `db/migrate/20260812110000_add_string_value_to_settings.rb` | `change` → explicit `up`/`down` |
| `app/models/setting.rb` | `DEFAULTS` → `INTEGER_DEFAULTS`; `allowed_extensions` entry format validation |
| `app/controllers/admin/settings_controller.rb` | handle string keys alongside integer keys |
| `app/views/admin/settings/show.html.erb` | render the list setting as a text field |
| `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` | 5 storage labels, revised `explanation`/`invalid`, new upload error messages |
| `app/models/game_file.rb` | `PERMITTED` constant |
| `config/deploy.yml` | storage volume, `max_request_body` |
| `spec/rails_helper.rb` | clear `tmp/storage` between examples |
| `spec/spec_helpers/fixtures_helper.rb` | `fixture_upload` helper |

---

## Task 1: Ignore the sqlite WAL sidecars

Pre-existing, unrelated to attachments, and outstanding since Phase 1's final review. Its own commit so it stays separable.

**Files:** Modify `.gitignore`

**Interfaces:** Consumes nothing. Produces nothing.

- [ ] **Step 1: Verify the gap exists**

```bash
cd /home/mezinster/encounter-engine
git check-ignore -v db/test.sqlite3        # matches *.sqlite3
git check-ignore -v db/test.sqlite3-wal    # expected: NO match, exit 1
```

- [ ] **Step 2: Add the rule**

In `.gitignore`, immediately after the existing `*.sqlite3` line:

```
# sqlite in WAL mode writes db/test.sqlite3-wal and -shm beside the database.
# *.sqlite3 does not match them: the glob requires the name to END in .sqlite3.
# Without this a `git add -A` after any test run stages a binary.
*.sqlite3-*
```

- [ ] **Step 3: Verify**

```bash
git check-ignore -v db/test.sqlite3-wal   # must now report *.sqlite3-*
git check-ignore -v db/test.sqlite3-shm   # must now report *.sqlite3-*
git check-ignore -v db/test.sqlite3       # must still report *.sqlite3
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "Ignore sqlite's WAL sidecar files

*.sqlite3 matches db/test.sqlite3 but not db/test.sqlite3-wal or -shm,
because the glob requires the name to end in .sqlite3. A git add -A after any
test run would stage a binary. Pre-existing and unrelated to attachments;
kept as its own commit so it stays separable."
```

---

## Task 2: The settings surface

**Files:**
- Modify: `db/migrate/20260812110000_add_string_value_to_settings.rb`
- Modify: `app/models/setting.rb`
- Modify: `app/controllers/admin/settings_controller.rb`
- Modify: `app/views/admin/settings/show.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/models/setting_spec.rb`, `spec/requests/admin_settings_spec.rb`

**Interfaces:**
- Consumes: `Setting::INTEGER_DEFAULTS`, `STRING_DEFAULTS`, `Setting.integer`, `Setting.list`, `Setting.put` (all shipped in Phase 1).
- Produces: `Setting::DEFAULTS == Setting::INTEGER_DEFAULTS` (nine keys on the admin page); `allowed_extensions` editable as free text; entries validated `/\A[a-z0-9]{1,10}\z/`. Tasks 3 and 4 read these values.

**Two locale strings become wrong when storage keys appear**, and fixing them is part of this task, not polish:
- `admin.settings.explanation` currently reads *"Ограничения действуют на один IP-адрес за указанный период. 0 отключает ограничение."* — it describes only rate limits.
- `admin.settings.invalid` currently reads *"Значение должно быть целым числом не меньше нуля"* — untrue once one field is a text list.

- [ ] **Step 1: Write the failing tests**

Add to `spec/models/setting_spec.rb`:

```ruby
describe "the storage keys reaching the admin page" do
  it "offers all nine integer keys" do
    expect(Setting::DEFAULTS.keys).to eq(Setting::INTEGER_DEFAULTS.keys)
  end

  it "still offers the four rate limits first" do
    expect(Setting::DEFAULTS.keys.first(4))
      .to eq(%w[signup_max signup_window_seconds reset_max reset_window_seconds])
  end
end

describe "allowed_extensions entry format" do
  it "accepts ordinary extensions" do
    expect { Setting.put("allowed_extensions", "jpg png pdf") }.not_to raise_error
  end

  it "rejects an entry with a dot" do
    expect { Setting.put("allowed_extensions", ".jpg") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects an entry with a slash, which is how a path would arrive" do
    expect { Setting.put("allowed_extensions", "jpg ../etc") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects an absurdly long entry" do
    expect { Setting.put("allowed_extensions", "a" * 11) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects a numeric value, which normalise_list would otherwise stringify" do
    # Phase 1 finding: Setting.put("allowed_extensions", 123) silently stored "123".
    expect { Setting.put("allowed_extensions", 123) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end

describe "integer settings, unchanged" do
  it "rejects nil for an integer key" do
    expect { Setting.put("signup_max", nil) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
```

Add to `spec/requests/admin_settings_spec.rb`:

The file already defines `let(:superadmin)` and signs in with `login_as(superadmin)`; these examples use that existing pattern rather than adding a helper.

```ruby
it "shows the storage settings to a superadmin" do
  login_as(superadmin)

  get admin_settings_path

  expect(response.body).to include("settings_game_quota_megabytes")
  expect(response.body).to include("settings_allowed_extensions")
end

it "stores a changed extension list" do
  login_as(superadmin)

  patch admin_settings_path, :params => { :settings => { "allowed_extensions" => "jpg pdf" } }

  expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
end

it "refuses a malformed extension list without writing it" do
  login_as(superadmin)
  Setting.put("allowed_extensions", "jpg pdf")

  patch admin_settings_path, :params => { :settings => { "allowed_extensions" => "jpg ../etc" } }

  expect(response).to have_http_status(:unprocessable_entity)
  expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
end
```

- [ ] **Step 2: Run them to confirm they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/setting_spec.rb spec/requests/admin_settings_spec.rb
```

Expected: failures on `DEFAULTS.keys`, on every format example (no validation yet), and on the request examples (fields absent).

- [ ] **Step 3: Flip `DEFAULTS` and add the format validation**

In `app/models/setting.rb`, replace the `DEFAULTS` line:

```ruby
  # What the admin settings page renders. Phase 1 deliberately kept this to the
  # four rate limits, because a settings screen offering a quota that no code
  # obeys is worse than no screen at all. Phase 2 adds the enforcement, so the
  # storage keys join it here -- together with their five
  # admin.settings.names.* labels in all seven locales, in this same change.
  DEFAULTS = INTEGER_DEFAULTS
```

and add, after the numericality validation:

```ruby
  # Entries are extensions, not free text. Without this,
  # Setting.put("allowed_extensions", 123) stored "123" and a stray path
  # fragment stored whatever it was given -- harmless only because PERMITTED
  # intersects the result, which is defence we should not have to rely on.
  # The lookahead requires at least one letter, and it is not decoration:
  # without it /\A[a-z0-9]{1,10}\z/ matches "123", so the very bug this
  # validation exists to close -- Setting.put("allowed_extensions", 123)
  # silently storing "123" -- would still pass.
  ENTRY = /\A(?=.*[a-z])[a-z0-9]{1,10}\z/
  validate :string_entries_are_well_formed, :if => :string_key?

  private

  def string_entries_are_well_formed
    self.class.normalise_list(string_value).each do |entry|
      next if entry.match?(ENTRY)

      errors.add(:string_value, :invalid)
    end
  end

  def string_key?
    STRING_DEFAULTS.key?(name)
  end
```

Keep `integer_key?` where it is; both predicates are private.

- [ ] **Step 4: Teach the controller about string keys**

In `app/controllers/admin/settings_controller.rb`, replace the body of `update`'s slice-and-write with:

```ruby
    permitted = Setting::INTEGER_DEFAULTS.keys + Setting::STRING_DEFAULTS.keys
    submitted = params.fetch(:settings, {}).to_unsafe_h.slice(*permitted)

    begin
      Setting.transaction do
        submitted.each do |name, value|
          # Integer(value, 10) rather than to_i for integer keys: "abc".to_i is
          # 0, which here means "disable this limit" -- a typo must not silently
          # switch a limit off. A string key is passed through untouched and
          # validated by the model.
          if Setting::STRING_DEFAULTS.key?(name)
            Setting.put(name, value)
          else
            Setting.put(name, Integer(value, 10))
          end
        end
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError, TypeError
```

leaving the existing `rescue` body and `record_admin_action` call unchanged.

- [ ] **Step 5: Render the list setting**

In `app/views/admin/settings/show.html.erb`, after the integer loop, add:

```erb
  <% Setting::STRING_DEFAULTS.keys.each do |name| %>
    <div class="field">
      <%= label_tag "settings_#{name}", t("admin.settings.names.#{name}") %>
      <%= text_field_tag "settings[#{name}]", Setting.list(name).join(" "), :id => "settings_#{name}" %>
    </div>
  <% end %>
```

and change `@values` construction in the controller's `current_values` from `Setting::DEFAULTS.keys` to `Setting::INTEGER_DEFAULTS.keys` — identical today, explicit about intent.

- [ ] **Step 6: Add the six new labels and revise two strings, in all seven locales**

For `config/locales/ru.yml`, under `admin.settings`:

```yaml
      explanation: "Ограничения на регистрацию действуют на один IP-адрес за указанный период; 0 отключает ограничение. Ограничения на файлы действуют на игру и на весь сервер."
      invalid: "Проверьте значения: числа должны быть целыми и не меньше нуля, расширения — латиницей и цифрами, без точек."
      names:
        signup_max: "Регистраций с одного адреса"
        signup_window_seconds: "Период для регистраций (секунд)"
        reset_max: "Запросов сброса пароля с одного адреса"
        reset_window_seconds: "Период для сброса пароля (секунд)"
        file_max_megabytes: "Максимальный размер файла (МБ)"
        max_files_per_upload: "Файлов за одну загрузку"
        game_quota_megabytes: "Квота на игру (МБ)"
        instance_cap_megabytes: "Общий лимит на сервер (МБ)"
        free_space_floor_megabytes: "Неснижаемый остаток на диске (МБ)"
        allowed_extensions: "Разрешённые расширения файлов"
```

**Six labels, not five.** The view added in Step 5 iterates `STRING_DEFAULTS`
as well as the integer keys and labels every one through
`t("admin.settings.names.#{name}")`, so `allowed_extensions` needs an entry too
— without it the page raises under `raise_on_missing_translations`.

Write the English equivalents in `en.yml` and translate for `uk ka tr be pl`. None of these keys interpolates a user-authored value, so the Turkish placeholder rule does not bite here.

- [ ] **Step 7: Convert the migration to explicit `up`/`down`**

Replace `def change` in `db/migrate/20260812110000_add_string_value_to_settings.rb` with:

```ruby
  def up
    add_column :settings, :string_value, :string
    change_column_null :settings, :value, true
  end

  # Explicit, because the auto-generated inverse of change_column_null is
  # change_column_null :settings, :value, false -- and that FAILS on both
  # SQLite and PostgreSQL as soon as any row has value IS NULL, which is every
  # string-key row by construction (Setting.put never sets `value` for those).
  # Phase 1 shipped this as `change` with a warning comment; phase 2 is what
  # wires the admin form to write string settings, so this is where the warning
  # has to become working code.
  #
  # Deleting the string rows is correct rather than destructive: they hold
  # operator settings that have shipped defaults in the model, so a row's
  # absence restores the default. The alternative -- refusing to roll back --
  # leaves an operator stuck mid-incident.
  def down
    execute("DELETE FROM settings WHERE value IS NULL")
    change_column_null :settings, :value, false
    remove_column :settings, :string_value
  end
```

`up` is byte-equivalent to the old `change`, so databases that already ran it stay consistent.

- [ ] **Step 8: Migrate, run the focused specs**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails db:test:prepare
bundle exec rspec spec/models/setting_spec.rb spec/requests/admin_settings_spec.rb spec/i18n_spec.rb
```

Expected: all pass. `spec/i18n_spec.rb` is in the list deliberately — it enforces `ru`↔`en` parity and will catch a label added to one file and forgotten in the other.

- [ ] **Step 9: Prove the rollback now works**

```bash
bin/rails db:migrate:status | grep 20260812110000
bin/rails runner 'Setting.put("allowed_extensions", "jpg pdf"); puts Setting.count'
bin/rails db:migrate:down VERSION=20260812110000
bin/rails db:migrate
bin/rails db:test:prepare
```

**`db:migrate:down VERSION=`, not `db:rollback STEP=1`.** Two later migrations
(`20260812120000_create_game_files`, `20260812130000_create_file_attachments`)
sit on top of this one, so `STEP=1` would roll back `create_file_attachments`
and prove nothing about the `down` this step exists to exercise.

Expected: the rollback succeeds rather than raising. That is the whole point of Step 7; if it raises, the `down` is wrong.

- [ ] **Step 10: Full suites and commit**

```bash
bundle exec rspec
bundle exec cucumber --format progress   # 232 scenarios / 2342 steps
bin/rails zeitwerk:check

git add app/models/setting.rb app/controllers/admin/settings_controller.rb \
        app/views/admin/settings/show.html.erb config/locales db/migrate \
        spec/models/setting_spec.rb spec/requests/admin_settings_spec.rb
git commit -m "Put the storage settings on the admin page, with enforcement coming

Phase 1 kept these five keys out of DEFAULTS on purpose: a settings screen
offering a quota that no code obeys is worse than no screen at all. Phase 2
adds the enforcement, so they join the page here -- with their labels in all
seven locales in the same change, which is what the phase 1 ruling required.

Two existing strings were quietly wrong the moment storage keys appeared.
explanation described only IP rate limits; invalid claimed every value must be
an integer, which stopped being true when one field became a text list.

allowed_extensions entries are now validated as extensions. Phase 1 found that
Setting.put(\"allowed_extensions\", 123) silently stored \"123\" -- harmless
only because PERMITTED intersects the result, which is defence we should not
have to lean on.

And the migration's rollback works. Phase 1 shipped it as change with a warning
comment that the auto-generated inverse would fail once any string row existed;
this phase is what creates those rows, so the warning had to become code."
```

---

## Task 3: The upload pipeline

**Files:**
- Create: `app/models/game_file_upload.rb`, `spec/models/game_file_upload_spec.rb`
- Create: `spec/fixtures/files/` (see Step 1)
- Modify: `app/models/game_file.rb` (add `PERMITTED`)
- Modify: `spec/spec_helpers/fixtures_helper.rb`, `spec/rails_helper.rb`
- Modify: `config/locales/*.yml` (upload error messages)

**Interfaces:**
- Consumes: `Setting.list("allowed_extensions")`, `Setting.integer("file_max_megabytes")` from Task 2; `GameFile` from Phase 1.
- Produces:
  - `GameFile::PERMITTED` — frozen `%w[jpg jpeg png gif heic pdf]`
  - `GameFileUpload.new(game, uploaded_file, uploaded_by).call → GameFile`
    Returns a **persisted** `GameFile` on success, or an **unsaved** one with `errors` populated on rejection. Never raises for ordinary rejection.
  - `GameFile#web_variant`, `GameFile#thumb_variant` → `ActiveStorage::Variant` or `nil` for PDF
  - Task 4 wraps `#call` with quota, cap and floor checks.

- [ ] **Step 1: Create the fixture files**

Real files, not fabrications — sniffing and conversion cannot be tested otherwise. Generate them with libvips and a here-doc:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
mkdir -p spec/fixtures/files
bundle exec ruby -e '
  require "image_processing/vips"
  Vips::Image.black(800, 600).write_to_file("spec/fixtures/files/photo.jpg")
  Vips::Image.black(40, 30).write_to_file("spec/fixtures/files/small.png")
  Vips::Image.black(40, 30).write_to_file("spec/fixtures/files/animation.gif")
  Vips::Image.black(800, 600).write_to_file("spec/fixtures/files/photo.heic")
'
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > spec/fixtures/files/map.pdf
printf '<html><script>alert(1)</script></html>' > spec/fixtures/files/not-really.jpg
```

Then add a GPS-tagged JPEG. libvips can write EXIF, so build it in the same runner:

```bash
bundle exec ruby -e '
  require "image_processing/vips"
  img = Vips::Image.black(200, 200)
  img = img.copy
  img.set_type(Vips::GVALUE_STR, "exif-ifd2-GPSLatitude", "42/1 52/1 0/1")
  img.write_to_file("spec/fixtures/files/geotagged.jpg")
'
```

Verify each one before relying on it:

```bash
bundle exec ruby -e '
  require "image_processing/vips"
  %w[photo.jpg small.png animation.gif photo.heic].each do |f|
    i = Vips::Image.new_from_file("spec/fixtures/files/#{f}")
    puts "#{f}: #{i.width}x#{i.height}"
  end
  puts "geotag present: " + Vips::Image.new_from_file("spec/fixtures/files/geotagged.jpg")
                                 .get_fields.grep(/GPS/).inspect
'
```

If the HEIC write fails, this host's libvips lacks HEIC — install `libvips42 libheif1` properly rather than dropping the fixture. **Report BLOCKED rather than removing the HEIC test.**

- [ ] **Step 2: Add the test helper and the storage cleanup hook**

In `spec/spec_helpers/fixtures_helper.rb`:

```ruby
  # An uploaded file as Rack would hand it to a controller. content_type is
  # deliberately a LIE in some specs: the pipeline must sniff bytes and ignore
  # what the client claims.
  def fixture_upload(name, claimed_type = "application/octet-stream")
    Rack::Test::UploadedFile.new(
      Rails.root.join("spec/fixtures/files", name), claimed_type
    )
  end
```

In `spec/rails_helper.rb`, beside the existing `Rails.cache.clear` hook:

```ruby
  # Active Storage's :test service writes real bytes to tmp/storage. Specs in
  # this suite attach real files, so without this they accumulate across runs.
  config.after(:each) do
    FileUtils.rm_rf(Rails.root.join("tmp/storage"))
  end
```

- [ ] **Step 3: Write the failing spec**

Create `spec/models/game_file_upload_spec.rb`:

```ruby
require "rails_helper"

describe GameFileUpload do
  before(:each) do
    @game = create_game
    @user = create_user
  end

  def upload(name, claimed_type = "application/octet-stream")
    GameFileUpload.new(@game, fixture_upload(name, claimed_type), @user).call
  end

  describe "accepting a photograph" do
    it "stores it, attached and persisted" do
      file = upload("photo.jpg")

      expect(file).to be_persisted
      expect(file.file).to be_attached
      expect(file.game).to eq(@game)
      expect(file.uploaded_by).to eq(@user)
    end

    it "records the sniffed content type, not the claimed one" do
      file = upload("photo.jpg", "application/pdf")

      expect(file.content_type).to eq("image/jpeg")
    end

    it "builds both variants eagerly, so reading never allocates disk" do
      file = upload("photo.jpg")

      expect(file.web_variant).to be_present
      expect(file.thumb_variant).to be_present
      expect(file.derived_byte_size).to be > 0
    end

    it "sets byte_size to the canonical bytes, not the upload" do
      file = upload("photo.jpg")

      expect(file.byte_size).to eq(file.file.byte_size)
    end
  end

  describe "rejecting" do
    it "a file whose bytes are HTML however it is named" do
      file = upload("not-really.jpg", "image/jpeg")

      expect(file).not_to be_persisted
      expect(file.errors[:file]).not_to be_empty
    end

    it "a type the operator removed from allowed_extensions" do
      Setting.put("allowed_extensions", "png")

      file = upload("photo.jpg")

      expect(file).not_to be_persisted
    end

    it "a type PERMITTED forbids even if the operator added it" do
      Setting.put("allowed_extensions", "jpg svg")

      expect(GameFile::PERMITTED).not_to include("svg")
    end

    it "a file larger than file_max_megabytes" do
      Setting.put("file_max_megabytes", 0)

      file = upload("photo.jpg")

      expect(file).not_to be_persisted
      expect(file.errors[:file]).not_to be_empty
    end
  end

  describe "canonicalisation" do
    it "strips EXIF, including the GPS that would give a location puzzle away" do
      file = upload("geotagged.jpg")

      file.file.open do |io|
        stored = Vips::Image.new_from_file(io.path)
        expect(stored.get_fields.grep(/GPS/)).to be_empty
      end
    end

    it "converts HEIC to JPEG and says so in the stored name" do
      file = upload("photo.heic")

      expect(file.content_type).to eq("image/jpeg")
      expect(file.filename).to end_with(".jpg")
    end

    it "leaves a PDF's bytes untouched and gives it no variants" do
      file = upload("map.pdf")

      expect(file.content_type).to eq("application/pdf")
      expect(file.web_variant).to be_nil
      expect(file.thumb_variant).to be_nil
      expect(file.derived_byte_size).to eq(0)
    end

    it "gives a GIF a thumb but leaves web as the original" do
      file = upload("animation.gif")

      expect(file.thumb_variant).to be_present
      expect(file.web_variant).to be_nil
    end
  end

  describe "filename collisions" do
    it "suffixes rather than overwriting, because a game may be running" do
      first  = upload("photo.jpg")
      second = upload("photo.jpg")

      expect(second).to be_persisted
      expect(second.filename).not_to eq(first.filename)
      expect(second.filename).to eq("photo-2.jpg")
    end

    it "retries once when the unique index fires under a race" do
      # The model validation is TOCTOU-racy against its own unique index.
      # Simulate the loser of that race: validation passes, the insert does not.
      # Stub save! (what the code calls), and use a plain local flag so the
      # first call raises and the retry reaches the real implementation.
      raised = false
      allow_any_instance_of(GameFile).to receive(:save!).and_wrap_original do |original, *args|
        unless raised
          raised = true
          raise ActiveRecord::RecordNotUnique, "simulated"
        end

        original.call(*args)
      end

      file = upload("photo.jpg")

      expect(file).to be_persisted
    end
  end

  it "sets all four denormalised fields in one place" do
    file = upload("photo.jpg")

    expect(file.byte_size).to be > 0
    expect(file.content_type).to be_present
    expect(file.checksum).to be_present
    expect(file.derived_byte_size).to be > 0
  end
end
```

- [ ] **Step 4: Run it to confirm it fails**

```bash
bundle exec rspec spec/models/game_file_upload_spec.rb
```

Expected: `uninitialized constant GameFileUpload`.

- [ ] **Step 5: Add `PERMITTED` to `GameFile`**

In `app/models/game_file.rb`, after the `belongs_to` lines:

```ruby
  # The ceiling on what may ever be uploaded, regardless of what a superadmin
  # puts in the allowed_extensions setting. Read as
  # `Setting.list("allowed_extensions") & GameFile::PERMITTED`.
  #
  # svg is absent on purpose and must stay absent: it is an image format that
  # executes JavaScript, so an <svg onload=...> served inline is stored XSS
  # against every playing team. html, xml and svgz are excluded for the same
  # reason. "Superadmin-manageable" is an operator convenience, not a trust
  # boundary -- a settings screen that can introduce a code-execution vector is
  # a privilege-escalation path wearing a config option's clothes.
  PERMITTED = %w[jpg jpeg png gif heic pdf].freeze

  # Extension → the canonical form it is stored as. HEIC becomes JPEG because
  # no browser but Safari can display HEIC.
  CANONICAL_EXTENSION = {
    "jpg" => "jpg", "jpeg" => "jpg", "heic" => "jpg",
    "png" => "png", "gif" => "gif", "pdf" => "pdf"
  }.freeze

  def web_variant
    return nil unless content_type.in?(%w[image/jpeg image/png])

    file.variant(:resize_to_limit => [ 1600, 1600 ]).processed
  end

  def thumb_variant
    return nil if content_type == "application/pdf"

    file.variant(:resize_to_limit => [ 320, 320 ]).processed
  end
```

- [ ] **Step 6: Write `GameFileUpload`**

Create `app/models/game_file_upload.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# The whole ingest path for one uploaded file, and the ONLY place that sets
# GameFile's four denormalised fields (byte_size, derived_byte_size,
# content_type, checksum). They duplicate what the blob knows, deliberately, so
# quota arithmetic needs no join -- and nothing keeps them in sync, so they get
# exactly one writer. A divergence silently corrupts quota accounting, which is
# a security control here rather than a nicety.
class GameFileUpload
  MIME_TO_EXTENSION = {
    "image/jpeg" => "jpg",
    "image/png"  => "png",
    "image/gif"  => "gif",
    "image/heic" => "heic",
    "image/heif" => "heic",
    "application/pdf" => "pdf"
  }.freeze

  def initialize(game, uploaded_file, uploaded_by)
    @game = game
    @uploaded_file = uploaded_file
    @uploaded_by = uploaded_by
  end

  def call
    game_file = GameFile.new(:game => @game, :uploaded_by => @uploaded_by)

    extension = sniffed_extension
    return reject(game_file, :unsupported_type) if extension.nil?
    return reject(game_file, :type_not_allowed) unless allowed?(extension)
    return reject(game_file, :too_large) if too_large?

    canonical = canonicalise(extension)

    game_file.filename = unique_filename(canonical[:filename])
    game_file.content_type = canonical[:content_type]

    attach_and_measure(game_file, canonical)
  rescue Vips::Error
    # A file that sniffs as an image and will not decode is not a valid image,
    # whatever its first bytes say.
    reject(GameFile.new(:game => @game, :uploaded_by => @uploaded_by), :unsupported_type)
  end

  private

  # Bytes only. Marcel accepts name: and declared_type: hints and PREFERS them,
  # and both are attacker-controlled -- passing the filename would reintroduce
  # exactly what this step exists to ignore.
  def sniffed_extension
    mime = File.open(@uploaded_file.tempfile.path, "rb") { |io| Marcel::MimeType.for(io) }
    MIME_TO_EXTENSION[mime]
  end

  def allowed?(extension)
    (Setting.list("allowed_extensions") & GameFile::PERMITTED).include?(extension)
  end

  def too_large?
    @uploaded_file.tempfile.size > Setting.integer("file_max_megabytes") * 1024 * 1024
  end

  # Raster images are decoded to pixels and re-encoded with every metadata
  # field dropped. That fixes HEIC, removes EXIF/GPS -- which on a
  # find-this-building puzzle IS the answer -- and is the strongest available
  # anti-polyglot defence: a file that is simultaneously valid JPEG and valid
  # HTML does not survive becoming pixels and being written back out.
  #
  # GIF is validated but NOT re-encoded: re-encoding an animated GIF either
  # loses the animation or needs frame-by-frame handling not worth its risk.
  # PDF cannot be re-encoded without ceasing to be a PDF.
  def canonicalise(extension)
    stem = File.basename(@uploaded_file.original_filename, ".*")
    target = GameFile::CANONICAL_EXTENSION.fetch(extension)

    if %w[gif pdf].include?(extension)
      return { :io => File.open(@uploaded_file.tempfile.path, "rb"),
               :filename => "#{stem}.#{target}",
               :content_type => extension == "gif" ? "image/gif" : "application/pdf" }
    end

    image = Vips::Image.new_from_file(@uploaded_file.tempfile.path)
    bytes = case target
            when "jpg" then image.write_to_buffer(".jpg", :strip => true, :Q => 88)
            when "png" then image.write_to_buffer(".png", :strip => true)
            end

    { :io => StringIO.new(bytes),
      :filename => "#{stem}.#{target}",
      :content_type => target == "jpg" ? "image/jpeg" : "image/png" }
  end

  # Unique per game. Suffixes rather than overwriting: a silent overwrite could
  # change a level in a running game.
  def unique_filename(candidate)
    stem = File.basename(candidate, ".*")
    ext  = File.extname(candidate)
    taken = GameFile.of_game(@game).pluck(:filename)

    return candidate unless taken.include?(candidate)

    (2..).each do |n|
      attempt = "#{stem}-#{n}#{ext}"
      return attempt unless taken.include?(attempt)
    end
  end

  def attach_and_measure(game_file, canonical)
    game_file.file.attach(:io => canonical[:io],
                          :filename => game_file.filename,
                          :content_type => canonical[:content_type])

    game_file.byte_size = game_file.file.byte_size
    game_file.checksum  = game_file.file.checksum

    save_with_collision_retry(game_file)

    # Variants are built eagerly, not on first request. With lazy variants a
    # player's page load would trigger a libvips run needing scratch disk, so a
    # full disk would break the PLAY SCREEN mid-race. Eager, it degrades to
    # "authors cannot upload right now" -- design invariant I1.
    derived = [ game_file.web_variant, game_file.thumb_variant ].compact
    game_file.update_column(:derived_byte_size, derived.sum { |v| v.blob.byte_size })

    game_file
  end

  # The model's uniqueness validation is time-of-check/time-of-use racy against
  # its own unique index: a concurrent upload of the same name passes validation
  # and loses at the insert. Unrescued that is a 500 for a name collision.
  def save_with_collision_retry(game_file)
    attempts = 0
    begin
      game_file.save!
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      raise if attempts > 1

      game_file.filename = unique_filename(game_file.filename)
      retry
    end
  end

  def reject(game_file, key)
    game_file.errors.add(:file, I18n.t("game_files.upload.#{key}"))
    game_file
  end
end
```

- [ ] **Step 7: Add the four error messages to all seven locales**

In `config/locales/ru.yml`, at the top level:

```yaml
  game_files:
    upload:
      unsupported_type: "Такой тип файла не поддерживается"
      type_not_allowed: "Загрузка файлов этого типа отключена администратором"
      too_large: "Файл слишком большой"
```

Write the English equivalents and translate for the other five. None interpolates a user-authored value.

- [ ] **Step 8: Run the spec**

```bash
bundle exec rspec spec/models/game_file_upload_spec.rb
```

Expected: all pass. If the collision-retry example is awkward to drive with `allow_any_instance_of`, replace it with a direct unit test of `save_with_collision_retry` — but **do not delete the case**; the rescue is what turns a 500 into a suffix.

- [ ] **Step 9: Full suites and commit**

```bash
bundle exec rspec
bundle exec cucumber --format progress   # 232 / 2342
bin/rails zeitwerk:check

git add app/models/game_file.rb app/models/game_file_upload.rb config/locales \
        spec/models/game_file_upload_spec.rb spec/spec_helpers/fixtures_helper.rb \
        spec/rails_helper.rb spec/fixtures/files
git commit -m "Add the upload pipeline: sniff, canonicalise, strip, measure

Sniffing is name-blind on purpose. Marcel accepts name: and declared_type:
hints and prefers them, and both come from the client -- passing the filename
would reintroduce exactly what this step exists to ignore. A .jpg whose bytes
are HTML is rejected.

Raster images are decoded to pixels and re-encoded with metadata stripped.
That fixes HEIC, removes the EXIF GPS that on a find-this-building puzzle IS
the answer, and is the strongest anti-polyglot defence available: a file that
is both valid JPEG and valid HTML does not survive becoming pixels. GIF keeps
its bytes (re-encoding loses the animation) and PDF cannot be re-encoded at
all, which is why PDFs get no variants.

PERMITTED ceilings the allowed_extensions setting rather than trusting it.
svg is absent and must stay absent: an image format that executes JavaScript is
stored XSS against every playing team, and a settings screen able to add one is
privilege escalation wearing a config option's clothes.

Variants are eager. Lazy ones would make a player's page load allocate scratch
disk, so a full disk would break the play screen mid-race instead of merely
refusing an upload.

One class sets all four denormalised fields, because nothing keeps them in sync
with the blob and a divergence corrupts quota accounting."
```

---

## Task 4: Disk protection

**Files:**
- Create: `app/models/disk_space.rb`, `spec/models/disk_space_spec.rb`
- Modify: `app/models/game_file_upload.rb`, `app/models/game_file.rb`
- Modify: `config/deploy.yml`
- Modify: `config/locales/*.yml`
- Test: `spec/models/game_file_upload_spec.rb`

**Interfaces:**
- Consumes: `GameFileUpload#call` from Task 3; `Setting.integer` for the four limits.
- Produces:
  - `DiskSpace.available_megabytes(path) → Integer`
  - `GameFile.storage_used_everywhere → Integer` (bytes, all games)
  - `#call` additionally rejects on quota, instance cap and floor.

- [ ] **Step 1: Write the failing specs**

Create `spec/models/disk_space_spec.rb`:

```ruby
require "rails_helper"

describe DiskSpace do
  it "reports a positive number of megabytes for a real path" do
    expect(DiskSpace.available_megabytes(Rails.root.to_s)).to be > 0
  end

  it "parses df's output rather than trusting its formatting" do
    output = "Filesystem     1024-blocks     Used Available Capacity Mounted on\n" \
             "/dev/sda1         30832548 17000000   3145728      56% /\n"
    allow(DiskSpace).to receive(:df_output).and_return(output)

    expect(DiskSpace.available_megabytes("/anything")).to eq(3072)
  end

  it "returns 0 rather than raising when df cannot answer" do
    # A refusal to write is the safe failure. Returning a large number because
    # the probe broke would disable the floor exactly when it is needed.
    allow(DiskSpace).to receive(:df_output).and_return("")

    expect(DiskSpace.available_megabytes("/anything")).to eq(0)
  end
end
```

Add to `spec/models/game_file_upload_spec.rb`:

```ruby
describe "disk protection" do
  it "refuses when the game is over its quota" do
    Setting.put("game_quota_megabytes", 0)

    file = upload("photo.jpg")

    expect(file).not_to be_persisted
    expect(file.errors[:file].join).to match(/\d/)   # the message carries numbers
  end

  it "refuses when the instance cap is reached" do
    Setting.put("instance_cap_megabytes", 0)

    expect(upload("photo.jpg")).not_to be_persisted
  end

  it "refuses when free space is below the floor" do
    allow(DiskSpace).to receive(:available_megabytes).and_return(10)
    Setting.put("free_space_floor_megabytes", 3072)

    file = upload("photo.jpg")

    expect(file).not_to be_persisted
  end

  it "allows when free space is above the floor" do
    allow(DiskSpace).to receive(:available_megabytes).and_return(9999)

    expect(upload("photo.jpg")).to be_persisted
  end

  it "counts variants against the quota, not just the canonical bytes" do
    first = upload("photo.jpg")

    expect(GameFile.storage_used_by(@game)).to eq(first.byte_size + first.derived_byte_size)
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

```bash
bundle exec rspec spec/models/disk_space_spec.rb spec/models/game_file_upload_spec.rb
```

Expected: `uninitialized constant DiskSpace`, and the quota examples persisting when they should not.

- [ ] **Step 3: Write `DiskSpace`**

Create `app/models/disk_space.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# Free space on the filesystem holding a given path.
#
# Shells out to df rather than adding sys-filesystem: Ruby's stdlib has no
# statvfs, this repository justifies every gem it carries, and df -kP is
# POSIX-specified output. Isolated in its own class so specs can stub the probe
# instead of filling a disk.
#
# This is the ONLY layer that sees the whole disk. The quota and instance-cap
# checks are arithmetic over our own records and are blind to Docker images,
# logs, Postgres growth and the other tenants on this host -- which is why the
# design promotes this from defence-in-depth to mandatory once it became clear
# no separate partition was available.
class DiskSpace
  def self.available_megabytes(path)
    line = df_output(path).lines[1]
    return 0 if line.nil?

    available_kb = line.split[3]
    return 0 if available_kb.nil?

    available_kb.to_i / 1024
  end

  # -P forces POSIX output: one line per filesystem, never wrapped, so the
  # fourth field is reliably "available". -k forces 1024-byte blocks.
  def self.df_output(path)
    `df -kP #{Shellwords.escape(path)} 2>/dev/null`
  rescue StandardError
    ""
  end
end
```

- [ ] **Step 4: Add the instance-wide sum**

In `app/models/game_file.rb`, beside `storage_used_by`:

```ruby
  # Bytes used across every game. Per-game quotas bound nothing on their own --
  # twenty games at a 100 MB quota is 2 GB whether or not the disk has it.
  def self.storage_used_everywhere
    sum(:byte_size) + sum(:derived_byte_size)
  end
```

- [ ] **Step 5: Wire the three checks into the pipeline**

In `app/models/game_file_upload.rb`, replace the body of `call`'s validation block. After the `too_large?` line and before `canonicalise`, insert:

```ruby
    return reject(game_file, :disk_full) unless room_on_disk?
    return reject(game_file, :instance_full) unless room_in_instance?
```

and wrap the persistence in the game's lock, replacing the `attach_and_measure` call with:

```ruby
    # The quota check is time-of-check/time-of-use: two uploads both read
    # "38 MB used of 100", both conclude they fit, both write, the game lands at
    # 62. The lock is held across check AND write. Overshoot would be survivable
    # only because the free-space floor is a hard backstop -- which is why that
    # floor must never later be dropped as redundant.
    #
    # No `return` inside the block: with_lock opens a transaction, and returning
    # out of a transaction block is a construct Rails has changed the semantics
    # of more than once. Assign and fall through instead.
    result = nil

    @game.with_lock do
      result =
        if room_in_quota?(incoming_size)
          attach_and_measure(game_file, canonical)
        else
          reject(game_file, :quota_full,
                 :left => left_megabytes, :quota => Setting.integer("game_quota_megabytes"))
        end
    end

    result
```

`left_megabytes` is the remaining allowance, floored at zero so a message never
reads a negative number:

```ruby
  def left_megabytes
    quota = Setting.integer("game_quota_megabytes") * 1024 * 1024
    [ quota - GameFile.storage_used_by(@game), 0 ].max / 1024 / 1024
  end
```

and add the predicates:

```ruby
  def incoming_size
    @uploaded_file.tempfile.size
  end

  def room_in_quota?(size)
    used = GameFile.storage_used_by(@game)
    used + size <= Setting.integer("game_quota_megabytes") * 1024 * 1024
  end

  def room_in_instance?
    GameFile.storage_used_everywhere + incoming_size <=
      Setting.integer("instance_cap_megabytes") * 1024 * 1024
  end

  def room_on_disk?
    DiskSpace.available_megabytes(Rails.root.to_s) >
      Setting.integer("free_space_floor_megabytes")
  end
```

Note `room_in_quota?` compares against the **uploaded** size, which over-counts for a HEIC that will shrink. That is deliberate: the check must happen before canonicalisation writes anything, so it uses the only size it has, and erring high is the safe direction.

- [ ] **Step 6: Add the three messages, with real numbers, in all seven locales**

`config/locales/ru.yml`, under `game_files.upload`:

```yaml
      quota_full: "Не хватает места в квоте игры: осталось %{left} МБ из %{quota} МБ"
      instance_full: "На сервере закончилось место для файлов"
      disk_full: "На диске сервера мало места, загрузка временно недоступна"
```

`quota_full` interpolates numbers, not user-authored names, so the Turkish rule does not apply. Pass the interpolations from `reject`:

```ruby
  def reject(game_file, key, interpolations = {})
    game_file.errors.add(:file, I18n.t("game_files.upload.#{key}", **interpolations))
    game_file
  end
```

and call it as
`reject(game_file, :quota_full, :left => left_megabytes, :quota => Setting.integer("game_quota_megabytes"))`.

- [ ] **Step 7: Raise the floor and add the deploy config**

In `app/models/setting.rb`, change `STORAGE_DEFAULTS`:

```ruby
    "free_space_floor_megabytes" => 3072
```

with a comment recording why it moved:

```ruby
    # 3072, not the 2048 phase 1 shipped. The floor's job changed: with no
    # separate partition available on this host, it is the only thing standing
    # between uploads and the next deploy. Sized from what it protects --
    # roughly two image pulls (561 MB each and growing), a rollback target, and
    # slack for the neighbouring tenants.
```

In `config/deploy.yml`, add to the app service:

```yaml
volumes:
  - encounter_engine_storage:/rails/storage
```

and under `proxy:`:

```yaml
  buffering:
    max_request_body: 67108864
```

with a comment:

```yaml
  # 64 MB. Ten files at the 25 MB per-file limit would be 250 MB of request body
  # buffered on a host with ~1.1 GB spare RAM. This is the only layer that acts
  # before Puma and before Rack writes a tempfile to /tmp. The cost: a batch
  # over this is rejected by kamal-proxy as a bare 413, before Rails can render
  # a translated message.
```

- [ ] **Step 8: Run everything, including the production probe**

```bash
bundle exec rspec
bundle exec cucumber --format progress   # 232 / 2342
bin/rails zeitwerk:check

RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com \
  SMTP_USERNAME=u SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com \
  DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'
```

- [ ] **Step 9: Commit**

```bash
git add app/models/disk_space.rb app/models/game_file.rb app/models/game_file_upload.rb \
        app/models/setting.rb config/deploy.yml config/locales \
        spec/models/disk_space_spec.rb spec/models/game_file_upload_spec.rb
git commit -m "Bound uploads by quota, instance cap and free space

Three checks, and the third is the only honest one. The quota and the instance
cap are arithmetic over our own records: they are blind to Docker images, logs,
Postgres growth and the other tenants sharing this disk. The free-space floor
is the only layer that sees the whole filesystem.

The floor rises from 2048 to 3072 MB because its job changed. The design wanted
a kernel-enforced partition boundary; the host has one block device and no
unallocated space, so the floor is now the only thing between uploads and the
next deploy -- and a deploy is exactly the capability you need in the state
where you have lost it. Sized from what it protects: two image pulls at 561 MB
and growing, a rollback target, and slack for a neighbour already sitting on
442 MB of unwatched logs.

The quota check runs inside game.with_lock across check AND write, because two
uploads reading \"38 of 100 MB used\" both conclude they fit. It compares the
UPLOADED size, which over-counts a HEIC that will shrink -- deliberate, since
the check must precede canonicalisation and erring high is the safe direction.

DiskSpace shells out to df rather than adding sys-filesystem; stdlib has no
statvfs and this repository justifies every gem. It returns 0 when the probe
fails, so a broken probe refuses writes instead of disabling the floor.

The storage volume is a prerequisite, not a follow-up: without it uploads live
in the container's writable layer and vanish at the next deploy."
```

---

## Phase 2A exit criteria

- [ ] `bundle exec rspec` green; Cucumber **232 scenarios / 2342 steps** unchanged.
- [ ] `bin/rails zeitwerk:check` clean; production boot probe prints `ok`.
- [ ] `bin/rails db:rollback STEP=1` on the settings migration succeeds with a string row present.
- [ ] `/admin/settings` renders nine integer fields and one text field, in Russian.
- [ ] No `.feature` file changed.

## Self-review notes

**Spec coverage.** Covers phase 2 spec §1 (all layers except L6/L7), §2 in full, §3's settings half, and §4's ledger items for this phase. **Deferred to Phase 2B:** the Explorer page (§3's Explorer half), the `_file_table` partial, the Russian `.feature` files, reclaim rake tasks and dashboard usage (L6/L7), and the `activerecord.errors.models.{game_file,file_attachment}` locale entries — those belong with the form that displays them.

**Known simplification, stated rather than hidden.** `GameFile#web_variant` / `#thumb_variant` call `.processed`, which builds the variant on demand if it is missing. Task 3 calls them at upload time, which is what makes generation eager; nothing in Phase 2A calls them on a read path. **Phase 2B and 3 must not call them from a request that serves a player** without confirming the variant already exists, or invariant I1 breaks.

**`GameFile.storage_used_everywhere` uses two `SUM` queries**, matching `storage_used_by`'s existing shape rather than introducing a SQL expression string — SQLite and PostgreSQL have disagreed about expression syntax in this codebase before.
