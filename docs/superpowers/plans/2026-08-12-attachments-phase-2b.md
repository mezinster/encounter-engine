# Attachments Phase 2B — the Explorer page and reclaim tooling

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give authors a per-game file Explorer — list, upload, delete — and give operators the tooling to see disk usage and reclaim space.

**Architecture:** One controller nested under `games`, one partial (`_file_table`) built in two modes so Phase 3's picker inherits it rather than inventing a second one, and two rake tasks. `GameFileUpload` (Phase 2A) does all the ingest work; the controller's job is authorization, batching and rendering. Nothing in the model layer changes except the locale entries that were deferred until these objects first appeared in a form.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, Active Storage Disk service, RSpec 3.13, Cucumber (Russian Gherkin), rack-test only — **no JavaScript**.

**Spec:** `docs/superpowers/specs/2026-08-12-attachments-phase-2-design.md` — §3 (Explorer, settings, reclaim), §6 units 4–5.

## Global Constraints

- **Ruby is not on `PATH` in non-login shells:** `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **`LD_LIBRARY_PATH` is NOT needed.** libvips with HEIC is installed system-wide.
- **Never edit an existing `.feature` file.** This plan **adds** new ones, which is allowed — they are port-authored, ordinary review, not amendments (see `CLAUDE.md`'s acceptance-suite rule). **The 232 inherited scenarios must still pass**; the total will rise, and each task states the expected new figure.
- **Hash rockets** (`:key => value`), including for symbol keys.
- **Every new user-facing string needs all seven locales** (`ru en uk ka tr be pl`); `raise_on_missing_translations = true` in test; `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity.
- **Turkish rule:** a key interpolating a user-authored value (a filename, a game name) must put the case suffix on a common noun, never on the placeholder.
- **`create_user` takes no arguments.** No FactoryBot.
- **No JavaScript.** The picker and Explorer must be drivable by rack-test: plain forms, `check`/`uncheck`, real `<a>`/`<button>`.
- **Neither suite evaluates `config/environments/production.rb`.**

---

## Two authorization facts that decide this phase's filters

Read `app/controllers/concerns/security_filters.rb` before writing the controller. Two things there are load-bearing and easy to get wrong by copying `LevelsController` wholesale:

1. **`ensure_author` already admits superadmins.** Its own comment calls it a "SECURITY CHOKEPOINT" and warns that *"any FUTURE call site of ensure_author silently admits superadmins too."* That is exactly the Explorer's rule (the game's author, or a superadmin for any game), so **use `ensure_author` and add nothing** — a parallel permission check would drift out of sync with the one every other controller uses.

2. **Do NOT apply `ensure_game_was_not_started`.** `LevelsController` applies it, and copying its filter list is the obvious move. It would break this feature: the design specifies a **typed confirmation for deleting a file attached to a level in a running game**, which presumes running games are reachable. Authors add and replace photos mid-quest; that is the point.

**`ensure_editing_not_locked` applies to `create` and `destroy` but NOT `index`.** Its comment states the rule directly: the lock covers content, settings and lifecycle, but *"Read-only views stay off this filter"* — an author under investigation may still look at their own game. Files are content, so writing is locked; listing is not.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `app/controllers/game_files_controller.rb` | authorization, batching, rendering; delegates all ingest to `GameFileUpload` |
| `app/views/game_files/index.html.erb` | the Explorer page: quota bar, upload form, the table |
| `app/views/game_files/_file_table.html.erb` | the table, in two modes — `:manage` (actions column) and `:picker` (checkbox column) |
| `lib/tasks/game_files.rake` | `game_files:purge_orphans`, `game_files:regenerate_variants` |
| `spec/requests/game_files_spec.rb` | authorization matrix and the three actions |
| `spec/views/game_files/file_table_spec.rb` | both partial modes |
| `spec/lib/tasks/game_files_rake_spec.rb` | the two rake tasks |
| `features/games/game-files.feature` | Russian: upload, quota refusal, delete-in-use |
| `features/games/steps/game-files_steps.rb` | its step definitions |

**Modified:**

| File | Change |
|---|---|
| `config/routes.rb` | `resources :game_files, only: [:index, :create, :destroy]` inside `resources :games` |
| `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` | Explorer copy, plus `activerecord.errors.models.{game_file,file_attachment}` |
| `app/controllers/admin/dashboard_controller.rb` | disk and storage figures |
| `app/views/admin/dashboard/show.html.erb` | a storage stat block |
| `app/views/games/show.html.erb` | a link to the Explorer |

---

## Task 1: Route, controller, and the Explorer listing

**Files:**
- Create: `app/controllers/game_files_controller.rb`, `app/views/game_files/index.html.erb`, `app/views/game_files/_file_table.html.erb`, `spec/requests/game_files_spec.rb`, `spec/views/game_files/file_table_spec.rb`
- Modify: `config/routes.rb`, `config/locales/*.yml`, `app/views/games/show.html.erb`

**Interfaces:**
- Consumes: `GameFile.of_game(game)`, `GameFile.storage_used_by(game)`, `GameFile#total_byte_size`, `Setting.integer("game_quota_megabytes")` (all Phase 1/2A).
- Produces: `game_game_files_path(game)`; the `_file_table` partial taking locals `:files`, `:mode` (`:manage` or `:picker`), and for picker mode `:field_name`. Phase 3 renders it in `:picker` mode.

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/game_files_spec.rb`:

```ruby
require "rails_helper"

describe "the game file Explorer", :type => :request do
  before(:each) do
    @author = create_user
    @game = create_game(:author => @author)
  end

  describe "authorization" do
    it "shows the Explorer to the game's author" do
      login_as(@author)

      get game_game_files_path(@game)

      expect(response).to have_http_status(:ok)
    end

    it "shows it to a superadmin for someone else's game" do
      admin = create_user
      admin.update!(:is_superadmin => true)
      login_as(admin)

      get game_game_files_path(@game)

      expect(response).to have_http_status(:ok)
    end

    it "refuses another author" do
      login_as(create_user)

      get game_game_files_path(@game)

      expect(response).not_to have_http_status(:ok)
    end

    it "refuses a signed-out visitor" do
      get game_game_files_path(@game)

      expect(response).not_to have_http_status(:ok)
    end

    it "still lists files for an author whose game is locked for editing" do
      # ensure_editing_not_locked covers content, settings and lifecycle, but
      # read-only views stay off it: an author under investigation may still
      # look at their own game.
      @game.update_column(:editing_locked_at, Time.now)
      login_as(@author)

      get game_game_files_path(@game)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the listing" do
    it "shows each file's name and where it is used" do
      level = create_level(:game => @game)
      file = create_game_file(:game => @game, :filename => "дом.jpg")
      FileAttachment.create!(:game_file => file, :attachable => level)
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).to include("дом.jpg")
      expect(response.body).to include(level.name)
    end

    it "says plainly when a file is attached to nothing" do
      create_game_file(:game => @game, :filename => "двор.jpg")
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).to include(I18n.t("game_files.index.unused"))
    end

    it "shows quota usage" do
      create_game_file(:game => @game, :byte_size => 5 * 1024 * 1024, :derived_byte_size => 0)
      login_as(@author)

      get game_game_files_path(@game)

      # 5 of 100 MB. The megabyte figure, not the byte count.
      expect(response.body).to include("5")
      expect(response.body).to include(Setting.integer("game_quota_megabytes").to_s)
    end

    it "does not list another game's files" do
      create_game_file(:game => create_game, :filename => "чужой.jpg")
      login_as(@author)

      get game_game_files_path(@game)

      expect(response.body).not_to include("чужой.jpg")
    end
  end
end
```

`login_as` is the existing request-spec helper — see `spec/requests/admin_settings_spec.rb`, which uses `login_as(superadmin)` with a `let`.

- [ ] **Step 2: Run it to confirm it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_files_spec.rb
```

Expected: `undefined local variable or method 'game_game_files_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the existing `resources :games do` block, beside `resources :levels`:

```ruby
    # The per-game file library. No :show -- a file is served by phase 3's
    # delivery route, which authorises per level/hint rather than per game.
    resources :game_files, :only => [ :index, :create, :destroy ]
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/game_files_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
#
# The per-game file library, for the game's author and for superadmins.
#
# All ingest work lives in GameFileUpload; this controller authorises, batches
# and renders. That split is deliberate: the upload pipeline is where the
# security model lives (sniffing, canonicalisation, the PERMITTED ceiling, the
# three disk guards) and it must not acquire a second entry point.
class GameFilesController < ApplicationController
  include SecurityFilters

  before_action :find_game
  # ensure_author ALREADY admits superadmins -- see the SECURITY CHOKEPOINT
  # comment in SecurityFilters. That is exactly this page's rule, so there is
  # no second permission check here; a parallel one would drift out of sync.
  before_action :ensure_author
  # Writing is content, so the editing lock applies. Listing is a read-only
  # view and deliberately stays off it, matching the filter's own comment.
  before_action :ensure_editing_not_locked, :only => [ :create, :destroy ]

  # NOTE: ensure_game_was_not_started is deliberately NOT applied. LevelsController
  # uses it and copying that filter list would break this feature: the design
  # specifies a typed confirmation for deleting a file attached to a level in a
  # RUNNING game, which presumes running games are reachable. Authors add and
  # replace photographs mid-quest.

  def index
    @files = GameFile.of_game(@game).order(:filename)
    @used_megabytes = GameFile.storage_used_by(@game) / 1024 / 1024
    @quota_megabytes = Setting.integer("game_quota_megabytes")
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end
end
```

- [ ] **Step 5: Write the table partial, in both modes**

Create `app/views/game_files/_file_table.html.erb`:

```erb
<%#
  Two modes, one partial. :manage gives an actions column (this phase);
  :picker gives a checkbox column (phase 3's level/hint form). Both are plain
  HTML so rack-test drives them -- the acceptance suite covers the picker with
  check/uncheck and needs no browser driver.

  Building both now means phase 3 inherits this component rather than growing
  a second table that drifts from this one.
%>
<table class="file-table">
  <tr>
    <th></th>
    <th><%= t("game_files.table.name") %></th>
    <th><%= t("game_files.table.size") %></th>
    <th><%= t("game_files.table.used_in") %></th>
    <th></th>
  </tr>

  <% files.each do |file| %>
    <tr>
      <td class="file-thumb"><%= file.content_type == "application/pdf" ? "PDF" : "IMG" %></td>
      <td><%= file.filename %></td>
      <td><%= number_to_human_size(file.total_byte_size) %></td>
      <td>
        <% places = file.file_attachments.map { |a| attachment_place(a) }.compact %>
        <%= places.any? ? places.join(", ") : t("game_files.index.unused") %>
      </td>
      <td>
        <% if mode == :picker %>
          <%= check_box_tag "#{field_name}[]", file.id, false, :id => "game_file_#{file.id}" %>
        <% else %>
          <%= button_to t("game_files.index.delete"),
                        game_game_file_path(file.game, file),
                        :method => :delete,
                        :form => { :data => { :confirm => t("game_files.index.confirm_delete") } } %>
        <% end %>
      </td>
    </tr>
  <% end %>
</table>
```

`attachment_place` is a helper; add it to `app/helpers/application_helper.rb`:

```ruby
  # "Уровень 3" or "Ур. 3 → подсказка 2". Returns nil for an attachment whose
  # owner has been destroyed, so a stale row renders as nothing rather than
  # raising on a live page.
  def attachment_place(attachment)
    case attachment.attachable
    when Level then attachment.attachable.name
    when Hint  then "#{attachment.attachable.level&.name} → #{t("game_files.table.hint")}"
    end
  end
```

- [ ] **Step 6: Write the index view**

Create `app/views/game_files/index.html.erb`:

```erb
<h1><%= t("game_files.index.title", :game => @game.name) %></h1>

<div class="quota-bar">
  <div class="quota-bar-fill"
       style="width: <%= [ (@used_megabytes * 100.0 / @quota_megabytes).round, 100 ].min %>%"></div>
</div>
<p class="hint-text">
  <%= t("game_files.index.quota", :used => @used_megabytes, :quota => @quota_megabytes) %>
</p>

<%= render "file_table", :files => @files, :mode => :manage, :field_name => nil %>
```

- [ ] **Step 7: Add the copy in all seven locales**

`config/locales/ru.yml`, at top level:

```yaml
  game_files:
    index:
      title: "Файлы игры «%{game}»"
      quota: "Занято %{used} МБ из %{quota} МБ"
      unused: "не используется"
      delete: "Удалить"
      confirm_delete: "Удалить файл?"
    table:
      name: "Имя файла"
      size: "Размер"
      used_in: "Где используется"
      hint: "подсказка"
```

`title` interpolates a user-authored game name. **In `tr.yml` the case suffix must go on a common noun**, e.g. `"«%{game}» adlı oyunun dosyaları"` — never on `%{game}` itself. Write `en.yml` at exact parity and translate the remaining five.

- [ ] **Step 8: Link it from the game page**

In `app/views/games/show.html.erb`, beside the existing author links:

```erb
<%= link_to t("game_files.index.title_short"), game_game_files_path(@game) %>
```

with `title_short: "Файлы"` added to the `game_files.index` block in all seven locales.

- [ ] **Step 9: Write the view spec for both modes**

Create `spec/views/game_files/file_table_spec.rb`:

```ruby
require "rails_helper"

describe "game_files/_file_table", :type => :view do
  before(:each) do
    @game = create_game
    @file = create_game_file(:game => @game, :filename => "дом.jpg")
  end

  it "renders an action button in manage mode" do
    render :partial => "game_files/file_table",
           :locals => { :files => [ @file ], :mode => :manage, :field_name => nil }

    expect(rendered).to include("дом.jpg")
    expect(rendered).to include(I18n.t("game_files.index.delete"))
  end

  it "renders a checkbox in picker mode, named for the form field" do
    # Phase 3 renders this mode inside the level form. It must be a real
    # checkbox so rack-test can check/uncheck it without a browser driver.
    render :partial => "game_files/file_table",
           :locals => { :files => [ @file ], :mode => :picker,
                        :field_name => "level[game_file_ids]" }

    expect(rendered).to include("level[game_file_ids][]")
    expect(rendered).to include(%(value="#{@file.id}"))
    expect(rendered).not_to include(I18n.t("game_files.index.delete"))
  end
end
```

- [ ] **Step 10: Run everything and commit**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_files_spec.rb spec/views/game_files/file_table_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber --format progress   # still 232 scenarios / 2342 steps -- this task adds no feature files
bin/rails zeitwerk:check

git add config/routes.rb app/controllers/game_files_controller.rb app/views/game_files \
        app/views/games/show.html.erb app/helpers/application_helper.rb config/locales \
        spec/requests/game_files_spec.rb spec/views/game_files
git commit -m "Add the game file Explorer listing

Authorization reuses ensure_author rather than adding a check: that filter
already admits superadmins, its own comment calls it a security chokepoint, and
a parallel permission system would drift out of sync with the one every other
controller uses.

Two filters are deliberately NOT copied from LevelsController.
ensure_game_was_not_started would break the feature outright -- the design
specifies a typed confirmation for deleting a file in a RUNNING game, which
presumes running games are reachable, because authors replace photographs
mid-quest. And ensure_editing_not_locked covers create/destroy but not index:
files are content so writing is locked, but the filter's own comment says
read-only views stay off it, so an author under investigation can still look.

The table is one partial in two modes. The picker mode has no caller until
phase 3, and is built now so phase 3 inherits this component instead of growing
a second table that drifts from it. Both modes are plain HTML: rack-test drives
check/uncheck with no browser driver, which is what keeps the picker inside the
acceptance suite."
```

---

## Task 2: Upload

**Files:**
- Modify: `app/controllers/game_files_controller.rb`, `app/views/game_files/index.html.erb`, `config/locales/*.yml`
- Test: `spec/requests/game_files_spec.rb`

**Interfaces:**
- Consumes: `GameFileUpload.new(game, uploaded_file, uploaded_by).call`, `GameFileUpload.batch_within_limit?(count)`, `GameFileUpload.batch_limit_message` (all Phase 2A).
- Produces: `POST /games/:game_id/game_files` accepting `params[:files]` as an array.

**This task gives `batch_within_limit?` its first caller.** Phase 2A shipped it deliberately unused; the batch ceiling must be enforced in the app and not only by kamal-proxy, which answers a bare 413 before Rails can render anything translated.

- [ ] **Step 1: Write the failing specs**

Add to `spec/requests/game_files_spec.rb`:

```ruby
describe "uploading" do
  def upload(names)
    post game_game_files_path(@game),
         :params => { :files => Array(names).map { |n| fixture_upload(n) } }
  end

  it "stores an accepted file" do
    login_as(@author)

    expect { upload("photo.jpg") }.to change { GameFile.count }.by(1)
    expect(response).to redirect_to(game_game_files_path(@game))
  end

  it "processes a batch per file, keeping the ones that fit" do
    # Per-file, not atomic: an author who picked one bad photo must not have to
    # re-select all the others.
    login_as(@author)

    expect { upload([ "photo.jpg", "not-really.jpg" ]) }.to change { GameFile.count }.by(1)
  end

  it "names the rejected file so the author knows which one failed" do
    login_as(@author)

    upload("not-really.jpg")

    expect(flash[:alert]).to include("not-really.jpg")
  end

  it "refuses a batch larger than max_files_per_upload without storing any of it" do
    Setting.put("max_files_per_upload", 1)
    login_as(@author)

    expect { upload([ "photo.jpg", "small.png" ]) }.not_to change { GameFile.count }
    expect(flash[:alert]).to eq(GameFileUpload.batch_limit_message)
  end

  it "refuses an upload to a game locked for editing" do
    @game.update_column(:editing_locked_at, Time.now)
    login_as(@author)

    expect { upload("photo.jpg") }.not_to change { GameFile.count }
  end

  it "refuses another author" do
    login_as(create_user)

    expect { upload("photo.jpg") }.not_to change { GameFile.count }
  end
end
```

`fixture_upload` is the Phase 2A helper in `spec/spec_helpers/fixtures_helper.rb`. **`small.png` was removed in Phase 2A as unreferenced** — recreate it in this task's Step 2, since this spec needs a second valid file.

- [ ] **Step 2: Recreate the second fixture**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec ruby -e '
  require "image_processing/vips"
  Vips::Image.black(40, 30).write_to_file("spec/fixtures/files/small.png")
'
```

- [ ] **Step 3: Run the specs to confirm they fail**

```bash
bundle exec rspec spec/requests/game_files_spec.rb -e uploading
```

Expected: routing error or `AbstractController::ActionNotFound` for `create`.

- [ ] **Step 4: Add the action**

In `app/controllers/game_files_controller.rb`:

```ruby
  def create
    submitted = Array(params[:files]).reject(&:blank?)

    unless GameFileUpload.batch_within_limit?(submitted.size)
      # The app must enforce this, not only kamal-proxy: the proxy answers a
      # bare 413 before Rails runs, so the author would get a browser error page
      # instead of a translated message.
      redirect_to game_game_files_path(@game), :alert => GameFileUpload.batch_limit_message
      return
    end

    rejected = submitted.filter_map do |uploaded|
      file = GameFileUpload.new(@game, uploaded, current_user).call
      next if file.persisted?

      "#{uploaded.original_filename}: #{file.errors[:file].join(", ")}"
    end

    # Per file, not atomic. An author who picked one oversized photo must not
    # have to re-select the other nine.
    redirect_to game_game_files_path(@game),
                :alert => (rejected.join("; ") if rejected.any?)
  end
```

- [ ] **Step 5: Add the form**

In `app/views/game_files/index.html.erb`, above the table:

```erb
<%= form_with url: game_game_files_path(@game), method: :post, multipart: true do %>
  <%= file_field_tag "files[]", :multiple => true %>
  <%= submit_tag t("game_files.index.upload"), class: "btn btn--go" %>
<% end %>

<p class="hint-text">
  <%= t("game_files.index.limits",
        :max => Setting.integer("file_max_megabytes"),
        :count => Setting.integer("max_files_per_upload")) %>
</p>
```

The limits line is not decoration: L0 rejects an oversized batch at kamal-proxy as a bare 413, before Rails can say anything, so the ceiling has to be visible before the author picks files.

- [ ] **Step 6: Add the copy in all seven locales**

`ru.yml`, in the `game_files.index` block:

```yaml
      upload: "Загрузить"
      limits: "До %{max} МБ на файл, не больше %{count} файлов за раз"
```

Neither interpolates a user-authored value, so the Turkish rule does not bite here.

- [ ] **Step 7: Run and commit**

```bash
bundle exec rspec spec/requests/game_files_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber --format progress   # still 232 / 2342
git add app/controllers/game_files_controller.rb app/views/game_files config/locales \
        spec/requests/game_files_spec.rb spec/fixtures/files/small.png
git commit -m "Let authors upload files through the Explorer

This gives GameFileUpload.batch_within_limit? its first caller. Phase 2A shipped
it deliberately unused because the count is only knowable one level up from a
class that ingests one file; this is that level. Enforcing it in the app matters
because L0's max_request_body is the proxy's ceiling, and the proxy answers a
bare 413 before Rails runs -- so without an app-side check the author gets a
browser error page instead of a translated message.

Uploads are processed per file rather than atomically: an author who picked one
oversized photo must not have to re-select the other nine. Rejections are
reported by filename so they know which."
```

---

## Task 3: Delete, with a typed confirmation for running games

**Files:**
- Modify: `app/controllers/game_files_controller.rb`, `app/views/game_files/_file_table.html.erb`, `config/locales/*.yml`
- Test: `spec/requests/game_files_spec.rb`

**Interfaces:**
- Consumes: `Game#status` (returns `:withdrawn | :draft | :finished | :running | :scheduled`).
- Produces: `DELETE /games/:game_id/game_files/:id`.

**The rule:** a file attached to a level or hint in a **running** game requires the author to type the filename to confirm. Anything else deletes with an ordinary confirm. `Game#status == :running` is the test — not `started?`, which is also true for finished games.

- [ ] **Step 1: Write the failing specs**

Add to `spec/requests/game_files_spec.rb`:

```ruby
describe "deleting" do
  it "removes an unused file and its blob" do
    file = create_game_file(:game => @game)
    login_as(@author)

    expect { delete game_game_file_path(@game, file) }.to change { GameFile.count }.by(-1)
  end

  it "removes an attached file when the game is not running" do
    level = create_level(:game => @game)
    file = create_game_file(:game => @game)
    FileAttachment.create!(:game_file => file, :attachable => level)
    login_as(@author)

    expect { delete game_game_file_path(@game, file) }.to change { GameFile.count }.by(-1)
  end

  it "refuses an attached file in a RUNNING game without the typed filename" do
    level = create_level(:game => @game)
    file = create_game_file(:game => @game, :filename => "дом.jpg")
    FileAttachment.create!(:game_file => file, :attachable => level)
    allow_any_instance_of(Game).to receive(:status).and_return(:running)
    login_as(@author)

    expect { delete game_game_file_path(@game, file) }.not_to change { GameFile.count }
  end

  it "accepts the typed filename in a running game" do
    level = create_level(:game => @game)
    file = create_game_file(:game => @game, :filename => "дом.jpg")
    FileAttachment.create!(:game_file => file, :attachable => level)
    allow_any_instance_of(Game).to receive(:status).and_return(:running)
    login_as(@author)

    expect {
      delete game_game_file_path(@game, file), :params => { :confirm_filename => "дом.jpg" }
    }.to change { GameFile.count }.by(-1)
  end

  it "does not accept a wrong typed filename" do
    # Otherwise the confirmation is theatre: any non-empty value would pass.
    level = create_level(:game => @game)
    file = create_game_file(:game => @game, :filename => "дом.jpg")
    FileAttachment.create!(:game_file => file, :attachable => level)
    allow_any_instance_of(Game).to receive(:status).and_return(:running)
    login_as(@author)

    expect {
      delete game_game_file_path(@game, file), :params => { :confirm_filename => "что-нибудь" }
    }.not_to change { GameFile.count }
  end

  it "refuses another author" do
    file = create_game_file(:game => @game)
    login_as(create_user)

    expect { delete game_game_file_path(@game, file) }.not_to change { GameFile.count }
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
bundle exec rspec spec/requests/game_files_spec.rb -e deleting
```

- [ ] **Step 3: Add the action**

```ruby
  def destroy
    file = GameFile.of_game(@game).find(params[:id])

    if typed_confirmation_required?(file) && params[:confirm_filename] != file.filename
      redirect_to game_game_files_path(@game),
                  :alert => t("game_files.index.type_the_filename", :filename => file.filename)
      return
    end

    file.destroy
    redirect_to game_game_files_path(@game), :notice => t("game_files.index.deleted")
  end

  private

  # Only for a file a live game is actually serving. :running specifically --
  # Game#started? is also true of a finished game, where deleting a photo harms
  # nobody.
  def typed_confirmation_required?(file)
    @game.status == :running && file.file_attachments.any?
  end
```

- [ ] **Step 4: Add the confirmation field to the table**

In `_file_table.html.erb`, replace the `button_to` in the manage branch with:

```erb
          <%= form_with url: game_game_file_path(file.game, file), method: :delete do %>
            <% if local_assigns[:typed_confirmation_for] == file.id %>
              <%= text_field_tag :confirm_filename, nil,
                                 :placeholder => file.filename,
                                 :id => "confirm_filename_#{file.id}" %>
            <% end %>
            <%= submit_tag t("game_files.index.delete") %>
          <% end %>
```

and in `index.html.erb` pass which files need it:

```erb
<% @files.each do |f| %>
<% end %>
<%= render "file_table", :files => @files, :mode => :manage, :field_name => nil,
                         :typed_confirmation_ids => @typed_confirmation_ids %>
```

with the controller's `index` computing:

```ruby
    @typed_confirmation_ids =
      @game.status == :running ? @files.select { |f| f.file_attachments.any? }.map(&:id) : []
```

Adjust the partial to read `local_assigns[:typed_confirmation_ids].to_a.include?(file.id)`.

- [ ] **Step 5: Add the copy in all seven locales**

```yaml
      deleted: "Файл удалён"
      type_the_filename: "Игра идёт. Чтобы удалить файл, введите его имя: %{filename}"
```

`type_the_filename` interpolates a **filename**, which is user-authored. **In `tr.yml` the suffix must fall on a common noun**, e.g. `"... dosyanın adını yazın: %{filename}"`.

- [ ] **Step 6: Run and commit**

```bash
bundle exec rspec spec/requests/game_files_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber --format progress   # still 232 / 2342
git add app/controllers/game_files_controller.rb app/views/game_files config/locales \
        spec/requests/game_files_spec.rb
git commit -m "Require the filename typed to delete a file a live game is serving

Game#status == :running, not started?, which is also true of a finished game
where deleting a photo harms nobody.

The wrong-filename case has its own example. Without it the confirmation is
theatre: any non-empty value would pass, and the test asserting that a typed
name works would happily pass alongside a check that never compares them."
```

---

## Task 4: The Russian acceptance features

**Files:**
- Create: `features/games/game-files.feature`, `features/games/steps/game-files_steps.rb`
- Test: the feature file is the test.

**This is the first task in the whole programme where the Cucumber total moves.** The invariant is not "232 scenarios" any more; it is **"the 232 inherited scenarios still pass"**. This task adds 3 scenarios. Record the new totals in the commit message so a later drift is visible.

New `.feature` files are permitted — see `CLAUDE.md`'s acceptance-suite rule: port-authored files change under ordinary review and are not amendments. **Do not touch any existing `.feature` file.**

- [ ] **Step 1: Write the feature**

Create `features/games/game-files.feature`:

```gherkin
#language: ru
Функционал: Файлы игры
  Как автор игры
  Я хочу загружать файлы и видеть, где они используются
  Чтобы добавлять фотографии к уровням и подсказкам

Сценарий: Загрузка файла
  Допустим пользователем Author1 создана игра "Котлованы"
  Если иду в файлы игры "Котлованы"
  И загружаю файл "photo.jpg"
  То должен увидеть "photo.jpg"
  И должен увидеть "не используется"

Сценарий: Файл слишком большой
  Допустим пользователем Author1 создана игра "Котлованы"
  И максимальный размер файла равен 0 МБ
  Если иду в файлы игры "Котлованы"
  И загружаю файл "photo.jpg"
  То не должен увидеть "photo.jpg"

Сценарий: Файл показывает, где он используется
  Допустим пользователем Author1 создана игра "Котлованы"
  И Author1 добавил задание "Уровень 1" в игру "Котлованы"
  Если иду в файлы игры "Котлованы"
  И загружаю файл "photo.jpg"
  И прикрепляю файл "photo.jpg" к уровню "Уровень 1"
  И иду в файлы игры "Котлованы"
  То должен увидеть "Уровень 1"
```

**Every setup step here already exists** — `пользователем X создана игра "Y"` (`features/games/steps/games_steps.rb:8`) registers the user, creates the game through the real form, and leaves the session logged in as them; `X добавил задание "L" в игру "G"` (`games_steps.rb:80`) does the same for a level. Do **not** write new steps for these. The login step (`features/authentication/steps/login_steps.rb:10`) registers through the UI and sets no `@current_user` instance variable, so a step definition that reaches for one would receive `nil` — which is exactly why these compose-from-existing-steps helpers exist.

- [ ] **Step 2: Write the step definitions**

Create `features/games/steps/game-files_steps.rb`:

Only four steps are genuinely new. The surrounding files use `Given /regex/` rather than Cucumber-expression syntax — match that:

```ruby
# -*- encoding : utf-8 -*-
Given /^максимальный размер файла равен (\d+) МБ$/ do |megabytes|
  Setting.put("file_max_megabytes", megabytes.to_i)
end

When /^иду в файлы игры "([^\"]*)"$/ do |game_name|
  visit game_game_files_path(Game.where(:name => game_name).first)
end

When /^загружаю файл "([^\"]*)"$/ do |filename|
  attach_file("files[]", Rails.root.join("spec/fixtures/files", filename))
  click_button(I18n.t("game_files.index.upload"))
end

When /^прикрепляю файл "([^\"]*)" к уровню "([^\"]*)"$/ do |filename, level_name|
  file = GameFile.where(:filename => filename).first
  level = Level.where(:name => level_name).first
  FileAttachment.create!(:game_file => file, :attachable => level)
end
```

Before writing these, grep `features/` for each phrase. Cucumber raises `Ambiguous match` on a duplicate definition, and the failure names the file but not always the obvious fix. `максимальный размер файла` and the three file steps have no existing counterpart; the game and level setup steps do, which is why they are not redefined here.

`attach_file` works under rack-test — no browser driver is needed for a plain multipart form, which is the whole reason the Explorer was built without JavaScript.

- [ ] **Step 3: Run the new feature alone**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec cucumber features/games/game-files.feature
```

Expected: 3 scenarios passing. If a step is reported ambiguous, resolve it by reusing the existing definition.

- [ ] **Step 4: Run the whole suite and record the new totals**

```bash
bundle exec cucumber --format progress
```

Expected: **235 scenarios** (232 + 3), and a step total 232's plus this file's. **Record the exact figures you observe in the commit message** — they become the new baseline.

- [ ] **Step 5: Commit**

```bash
git add features/games/game-files.feature features/games/steps/game-files_steps.rb
git commit -m "Cover the Explorer with Russian acceptance scenarios

The first change in this programme that moves the Cucumber total. The invariant
is no longer '232 scenarios' but 'the 232 inherited scenarios still pass' --
these are port-authored files, which CLAUDE.md's acceptance-suite rule allows
under ordinary review and does not count as amendments.

New totals recorded here so a later drift is visible: <FILL IN OBSERVED FIGURES>."
```

**Replace `<FILL IN OBSERVED FIGURES>` with the actual scenario and step counts from Step 4.** Do not guess them.

---

## Task 5: Reclaim tooling and dashboard usage

**Files:**
- Create: `lib/tasks/game_files.rake`, `spec/lib/tasks/game_files_rake_spec.rb`
- Modify: `app/controllers/admin/dashboard_controller.rb`, `app/views/admin/dashboard/show.html.erb`, `config/locales/*.yml`

**Interfaces:**
- Consumes: `GameFile.storage_used_everywhere`, `DiskSpace.available_megabytes(path)`, `GameFileUpload` (private `measure_derived!` is NOT public — regeneration must go through the model's own variant methods).
- Produces: `rake game_files:purge_orphans`, `rake game_files:regenerate_variants`.

**`regenerate_variants` must rewrite `derived_byte_size`, not just the blobs.** It is the only reconciliation path for an undercount — Phase 2A's post-commit measurement can leave a row at 0 if the process dies between commit and update, and nothing else ever revisits it.

- [ ] **Step 1: Write the failing spec**

Create `spec/lib/tasks/game_files_rake_spec.rb`:

```ruby
require "rails_helper"
require "rake"

describe "game_files rake tasks" do
  before(:all) do
    Rake.application.rake_require("tasks/game_files", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  before(:each) do
    Rake::Task.tasks.each(&:reenable)
    @game = create_game
  end

  describe "game_files:regenerate_variants" do
    it "rewrites derived_byte_size for a row left at zero" do
      # This is the ONLY reconciliation path for an undercount: phase 2A measures
      # variants after commit, so a process killed in between leaves a row at 0
      # that nothing else revisits.
      file = GameFileUpload.new(@game, fixture_upload("photo.jpg"), create_user).call
      file.update_column(:derived_byte_size, 0)

      Rake::Task["game_files:regenerate_variants"].invoke

      expect(file.reload.derived_byte_size).to be > 0
    end

    it "leaves a PDF at zero, because a PDF has no variants" do
      file = GameFileUpload.new(@game, fixture_upload("map.pdf"), create_user).call

      Rake::Task["game_files:regenerate_variants"].invoke

      expect(file.reload.derived_byte_size).to eq(0)
    end
  end

  describe "game_files:purge_orphans" do
    it "purges a blob attached to nothing" do
      ActiveStorage::Blob.create_and_upload!(
        :io => StringIO.new("orphan"), :filename => "orphan.bin",
        :content_type => "application/octet-stream"
      )

      expect { Rake::Task["game_files:purge_orphans"].invoke }
        .to change { ActiveStorage::Blob.unattached.count }.to(0)
    end

    it "leaves an attached blob alone" do
      # Without this the task could satisfy its own test by purging everything.
      file = GameFileUpload.new(@game, fixture_upload("photo.jpg"), create_user).call

      Rake::Task["game_files:purge_orphans"].invoke

      expect(file.reload.file).to be_attached
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
bundle exec rspec spec/lib/tasks/game_files_rake_spec.rb
```

Expected: `Don't know how to build task 'game_files:regenerate_variants'`.

- [ ] **Step 3: Write the tasks**

Create `lib/tasks/game_files.rake`:

```ruby
# -*- encoding : utf-8 -*-
namespace :game_files do
  desc "Purge Active Storage blobs attached to nothing"
  task :purge_orphans => :environment do
    count = ActiveStorage::Blob.unattached.count
    ActiveStorage::Blob.unattached.find_each(&:purge)
    puts "purged #{count} unattached blob(s)"
  end

  desc "Rebuild every file's variants and rewrite derived_byte_size"
  task :regenerate_variants => :environment do
    GameFile.find_each do |file|
      derived = [ file.web_variant, file.thumb_variant ].compact
      # v.image, not v.record.image: #record is PRIVATE on
      # ActiveStorage::VariantWithRecord (variant_with_record.rb:38) and #image
      # (line 23) is the public accessor to the same tracked derivative. And
      # not v.blob -- that is the attr_reader holding the SOURCE blob, which is
      # what made derived_byte_size record canonical_size x N for a whole phase.
      file.update_column(:derived_byte_size, derived.sum { |v| v.image.blob.byte_size })
    rescue StandardError => e
      # One bad file must not stop the reconciliation of every other.
      warn "#{file.id} #{file.filename}: #{e.class}"
    end
    puts "regenerated variants for #{GameFile.count} file(s)"
  end
end
```

- [ ] **Step 4: Add the dashboard figures**

In `app/controllers/admin/dashboard_controller.rb`'s `show`:

```ruby
    @storage_used_megabytes = GameFile.storage_used_everywhere / 1024 / 1024
    @storage_cap_megabytes = Setting.integer("instance_cap_megabytes")
    @disk_free_megabytes = DiskSpace.available_megabytes(Rails.root.to_s)
    @disk_floor_megabytes = Setting.integer("free_space_floor_megabytes")
```

In `app/views/admin/dashboard/show.html.erb`, after the existing stat grids:

```erb
<h2><%= t("admin.dashboard.show.storage") %></h2>
<div class="stat-grid">
  <div class="stat">
    <div class="stat-value"><%= @storage_used_megabytes %></div>
    <div class="stat-label"><%= t("admin.dashboard.show.storage_used") %></div>
  </div>
  <div class="stat">
    <div class="stat-value"><%= @storage_cap_megabytes %></div>
    <div class="stat-label"><%= t("admin.dashboard.show.storage_cap") %></div>
  </div>
  <div class="stat">
    <div class="stat-value"><%= @disk_free_megabytes %></div>
    <div class="stat-label"><%= t("admin.dashboard.show.disk_free") %></div>
  </div>
  <div class="stat">
    <div class="stat-value"><%= @disk_floor_megabytes %></div>
    <div class="stat-label"><%= t("admin.dashboard.show.disk_floor") %></div>
  </div>
</div>
```

- [ ] **Step 5: Add the model error messages that were deferred to this phase**

Phase 1 deferred these until the objects first appeared in a form. That is now. In `config/locales/ru.yml`:

```yaml
    activerecord:
      errors:
        models:
          game_file:
            attributes:
              filename:
                taken: "Файл с таким именем уже есть в этой игре"
          file_attachment:
            attributes:
              attachable:
                inclusion: "Нельзя прикрепить файл к чужой игре"
              game_file:
                inclusion: "Этот файл принадлежит другой игре"
```

Without these, a validation failure renders *"Game file не может быть пустым"* — an English attribute name inside a Russian sentence. Add the same structure to all seven files, plus the four dashboard labels.

- [ ] **Step 6: Run everything and commit**

```bash
bundle exec rspec spec/lib/tasks/game_files_rake_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber --format progress   # the Task 4 figure, unchanged
bin/rails zeitwerk:check

git add lib/tasks/game_files.rake app/controllers/admin/dashboard_controller.rb \
        app/views/admin/dashboard/show.html.erb config/locales \
        spec/lib/tasks/game_files_rake_spec.rb
git commit -m "Add reclaim tooling and storage figures on the admin dashboard

regenerate_variants rewrites derived_byte_size, not just the blobs. That is the
point of it: phase 2A measures variants AFTER commit, so a process killed in
between leaves a row consuming quota with derived_byte_size at 0, and nothing
else ever revisits it. This is the only reconciliation path that exists.

Both tasks have a negative counterpart in their specs -- purge_orphans is
checked to LEAVE an attached blob alone, because otherwise it could satisfy its
own test by purging everything.

Also lands the activerecord.errors.models entries phase 1 deferred until these
objects first appeared in a form: without them a validation failure renders
'Game file не может быть пустым', an English attribute name inside a Russian
sentence."
```

---

## Phase 2B exit criteria

- [ ] `bundle exec rspec` green.
- [ ] Cucumber: **the 232 inherited scenarios still pass**, and the new total matches what Task 4 recorded.
- [ ] `bin/rails zeitwerk:check` clean; production boot probe prints `ok`.
- [ ] An author can list, upload and delete files; a superadmin can do the same for any game; a stranger gets neither.
- [ ] Deleting an attached file in a running game requires the typed filename, and a wrong name is refused.
- [ ] `rake game_files:regenerate_variants` rewrites `derived_byte_size`.
- [ ] No existing `.feature` file changed.

## Self-review notes

**Spec coverage.** Covers the phase 2 spec's §3 in full (Explorer, the `_file_table` partial in both modes, deletion with typed confirmation, the settings surface having landed in 2A, reclaim tooling and dashboard usage) and §6 units 4–5. Carried items discharged: `batch_within_limit?` gains its caller in Task 2; the `activerecord.errors.models.*` entries land in Task 5.

**Known deferrals, stated rather than hidden.** The Explorer has no thumbnail images — the table shows a text marker (`IMG`/`PDF`) because serving a file requires the delivery route with its authorization matrix, which is **Phase 3**. Rendering a real `<img>` here would need either that route or a public one, and a public one is what the design rejected. Phase 3 replaces the marker with a real thumbnail once the authorized route exists.

**A trap this plan deliberately avoids.** Task 3's "wrong typed filename" example exists because without it the confirmation is theatre: a check that merely requires `confirm_filename` to be *present* would pass every positive test while accepting any input. This programme produced six checks that were green while proving nothing; that is the shape of the seventh.
