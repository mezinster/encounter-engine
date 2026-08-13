# Attachments Phase 3A — delivery and authorization

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve attached files over one authorized route, so that every byte a player receives has been checked against the §4 matrix, and no byte reaches anyone else.

**Architecture:** One route, one controller, one policy object. `FileDeliveriesController#show` resolves the game and file, asks `GameFileAccess` whether this requester may have it, then streams the requested variant with headers that stop the browser guessing the type and stop a shared proxy caching an authorized response. Authorization lives in `GameFileAccess` rather than the controller so it can be tested without HTTP and reused by Phase 3B's play screen, which must decide whether to render a strip at all.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, Active Storage (Disk service), RSpec request specs, SQLite in test.

## Global Constraints

- **`features/**/*.feature` files are frozen.** The 58 inherited Russian files (232 scenarios / 2342 steps) must not be edited. This phase adds no feature file; verify `git diff <base>..HEAD -- features/` is empty at the end.
- **Seven locales** — `ru en uk ka tr be pl`, `ru` default, fallbacks to `ru`. The test environment sets `raise_on_missing_translations`, so a missing key raises. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and subset-only for the other five. This phase should add **no** user-facing string: every failure path is an HTTP status, not a rendered message.
- **The repository is public.** No secrets, tokens, or absolute developer paths in committed files.
- **Hash rockets** (`:key => value`) throughout, including symbol keys. Match the surrounding file.
- **Comments and identifiers in English**; user-facing strings in Russian via `t()`.
- **`create_user` takes no arguments.** Factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` — `create_user`, `create_game`, `create_level`. Not FactoryBot.
- **Baseline to hold:** RSpec 1603 examples / 0 failures / 6 pending. Cucumber 238 scenarios (2 undefined, 236 passed) / 2386 steps, of which **232 / 2342 is the inherited contract that must not move**.
- Run the full suite at the end of every task, not only at the end of the phase.

## File Structure

| File | Responsibility |
|---|---|
| `config/routes.rb` (modify) | One route: `GET /games/:game_id/files/:id/:variant` |
| `app/models/game_file_access.rb` (create) | The §4 matrix, as a plain object. No HTTP, no controller state. |
| `app/controllers/file_deliveries_controller.rb` (create) | Resolve, authorize, set headers, stream. Nothing else. |
| `spec/models/game_file_access_spec.rb` (create) | The matrix at unit level, every row and every denial |
| `spec/requests/file_deliveries_spec.rb` (create) | The matrix over real HTTP, plus headers and robustness |

**Why a separate controller.** `GameFilesController` is author-only: `before_action :ensure_author` gates every action. This controller must admit *players*, who are not authors. Adding a player-visible action there would put a public path behind a filter chain designed for a private one, one `:except` away from serving an author's whole library to anyone. Separate controller, separate filters, no shared surface.

---

### Task 1: The route, the controller skeleton, and the author/superadmin rows

**Files:**
- Modify: `config/routes.rb` (near the `game_files` resources, ~line 143)
- Create: `app/models/game_file_access.rb`
- Create: `app/controllers/file_deliveries_controller.rb`
- Create: `spec/models/game_file_access_spec.rb`
- Create: `spec/requests/file_deliveries_spec.rb`

**Interfaces:**
- Consumes: `GameFile` (`#game`, `#file`, `#content_type`, `#filename`, `#checksum`, `#web_variant`, `#thumb_variant`), `User#author_of?(game)`, `User#superadmin?`
- Produces: `GameFileAccess.new(user, game_file).permitted?` → boolean, used again in Task 2 and by Phase 3B. `FileDeliveriesController#show`.

- [ ] **Step 1: Write the failing spec for the policy object's author rows**

```ruby
# spec/models/game_file_access_spec.rb
require "rails_helper"

describe GameFileAccess do
  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @file   = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
  end

  it "permits the game's author" do
    expect(GameFileAccess.new(@author, @file).permitted?).to be true
  end

  it "permits a superadmin who is not the author" do
    admin = create_user
    admin.update_column(:is_superadmin, true)

    expect(GameFileAccess.new(admin, @file).permitted?).to be true
  end

  it "refuses the author of a DIFFERENT game" do
    # Not "some logged-in user" -- an author specifically. authorship is
    # per game, and a policy that checked `user.author_of_anything?` would
    # pass this and hand every author every other author's library.
    other = create_user
    create_game(:author => other)

    expect(GameFileAccess.new(other, @file).permitted?).to be false
  end

  it "refuses an anonymous requester" do
    expect(GameFileAccess.new(nil, @file).permitted?).to be false
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/models/game_file_access_spec.rb`
Expected: FAIL — `uninitialized constant GameFileAccess`.

- [ ] **Step 3: Write the policy object with only the author rows**

```ruby
# app/models/game_file_access.rb
# -*- encoding : utf-8 -*-
#
# The §4 authorization matrix from
# docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md.
#
# A plain object rather than controller filters, for two reasons. It is the
# security contract, so it is worth testing without an HTTP round trip; and
# phase 3B's play screen needs the same answer BEFORE rendering, to decide
# whether a strip appears at all -- a view that renders <img> tags the
# delivery route will 404 is worse than one that renders nothing.
class GameFileAccess
  def initialize(user, game_file)
    @user = user
    @game_file = game_file
  end

  def permitted?
    return false if @user.nil? || @game_file.nil?
    return true  if author_or_superadmin?

    false
  end

  private

  def game = @game_file.game

  def author_or_superadmin?
    return false if game.nil?

    @user.superadmin? || @user.author_of?(game)
  end
end
```

- [ ] **Step 4: Run the spec and watch it pass**

Run: `bundle exec rspec spec/models/game_file_access_spec.rb`
Expected: 4 examples, 0 failures.

- [ ] **Step 5: Add the route**

In `config/routes.rb`, inside the existing `resources :games do` block, immediately after the `resources :game_files` line whose comment already promises this route:

```ruby
    # Phase 3's delivery route. Deliberately NOT `resources :game_files, :only
    # => [:show]`: that controller is author-only, and this path must admit
    # playing teams. :variant is matched against a hard-coded whitelist in the
    # controller and never becomes a path component.
    get "files/:id/:variant", :to => "file_deliveries#show", :as => :game_file_delivery,
                              :constraints => { :variant => /original|web|thumb/ }
```

- [ ] **Step 6: Write the failing request specs for the author rows**

```ruby
# spec/requests/file_deliveries_spec.rb
require "rails_helper"

describe "file delivery", :type => :request do
  # Defined here, not shared: Phase 2B's spec/requests/game_files_spec.rb
  # defines its own copy at line 4 and there is no shared request-spec login
  # helper in spec/spec_helpers/. Copy this shape verbatim -- create_user
  # generates the password "1234", which is what makes this work.
  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @file   = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
  end

  def deliver(variant = "original")
    get game_file_delivery_path(@game, @file, variant)
  end

  it "serves the original to the game's author" do
    login_as @author
    deliver

    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(@file.byte_size)
  end

  it "404s for a logged-out requester" do
    deliver
    expect(response).to have_http_status(:not_found)
  end

  it "404s for a signed-in user with no connection to the game" do
    # 404, NOT 403: a 403 confirms the file exists, which tells an attacker
    # enumerating ids exactly which ones are real.
    login_as create_user
    deliver

    expect(response).to have_http_status(:not_found)
  end

  it "404s for a file id belonging to a different game" do
    other_game = create_game(:author => @author)
    other_file = GameFileUpload.new(other_game, fixture_upload("map.pdf"), @author).call

    login_as @author
    get game_file_delivery_path(@game, other_file, "original")

    expect(response).to have_http_status(:not_found)
  end

  it "404s for a variant name outside the whitelist" do
    login_as @author
    get "/games/#{@game.id}/files/#{@file.id}/../../../etc/passwd"

    expect(response).to have_http_status(:not_found)
  end
end
```

**Note on `login_as`:** check `spec/spec_helpers/` for the established request-spec login helper and use it verbatim rather than inventing one; if none exists, follow whatever `spec/requests/game_files_spec.rb` (Phase 2B) does.

- [ ] **Step 7: Run and watch them fail**

Run: `bundle exec rspec spec/requests/file_deliveries_spec.rb`
Expected: FAIL — no controller.

- [ ] **Step 8: Write the controller**

```ruby
# app/controllers/file_deliveries_controller.rb
# -*- encoding : utf-8 -*-
#
# Every attached byte a player receives comes through here. See §4 of
# docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md.
class FileDeliveriesController < ApplicationController
  # The whitelist. A requested variant is matched against this before anything
  # touches storage, and the matched value is used to pick a METHOD, never to
  # build a path -- so no request-supplied string reaches the filesystem.
  VARIANTS = %w[original web thumb].freeze

  def show
    game = Game.find_by(:id => params[:game_id])
    file = game && GameFile.find_by(:id => params[:id], :game_id => game.id)

    # One refusal for every failure: missing game, missing file, wrong game,
    # unknown variant, not permitted. A distinct status for any of them tells
    # an id-enumerating attacker which guesses were right.
    return head(:not_found) if file.nil?
    return head(:not_found) unless VARIANTS.include?(params[:variant])
    return head(:not_found) unless GameFileAccess.new(current_user, file).permitted?

    deliver(file, params[:variant])
  end

  private

  def deliver(file, variant)
    blob = blob_for(file, variant)
    return head(:not_found) if blob.nil?

    send_data blob.download, :type => file.content_type,
                             :filename => file.filename,
                             :disposition => "inline"
  end

  # Returns nil rather than raising when the variant does not apply to this
  # content type -- web_variant is nil for GIF, thumb_variant is nil for PDF.
  # Task 4 extends this to the case where the BLOB is gone.
  def blob_for(file, variant)
    case variant
    when "original" then file.file
    when "web"      then file.web_variant&.image
    when "thumb"    then file.thumb_variant&.image
    end
  end
end
```

- [ ] **Step 9: Run both spec files and watch them pass**

Run: `bundle exec rspec spec/models/game_file_access_spec.rb spec/requests/file_deliveries_spec.rb`
Expected: 9 examples, 0 failures.

- [ ] **Step 10: Prove the whitelist is load-bearing**

Temporarily delete the `VARIANTS.include?` guard and confirm the "variant name outside the whitelist" example fails. Restore it. Record the failure output in your report — a whitelist nobody has seen reject anything is a comment, not a control.

- [ ] **Step 11: Run the full suite**

Run: `bundle exec rspec` then `bundle exec cucumber`
Expected: RSpec 1612 / 0 / 6. Cucumber unchanged at 238 scenarios / 2386 steps.

- [ ] **Step 12: Commit**

```bash
git add config/routes.rb app/models/game_file_access.rb app/controllers/file_deliveries_controller.rb spec/models/game_file_access_spec.rb spec/requests/file_deliveries_spec.rb
git commit -m "One route for every attached byte, author rows first"
```

---

### Task 2: The playing-team rows

This is the security-critical half. A team may fetch a file attached to the level they are **on**, to any level they have **already passed**, and to hints on their current level that have **already fired**. Everything else is a 404.

**Files:**
- Modify: `app/models/game_file_access.rb`
- Modify: `spec/models/game_file_access_spec.rb`
- Modify: `spec/requests/file_deliveries_spec.rb`

**Interfaces:**
- Consumes: `GamePassing` (`#current_level`, `#current_level_entered_at`, `#hints_to_show`, `#finished?`), `Level#position`, `FileAttachment#attachable`, `Hint#ready_to_show?(entered_at, now)`, `GamePassing#effective_now`
- Produces: no new public API — `permitted?` simply becomes complete.

**Domain facts established by reading the code — do not re-derive, but do verify before relying on:**
- Levels are ordered by `position`: `has_many :levels, -> { order('position') }` in `app/models/game.rb:17`.
- `GamePassing#advance` does `self.current_level = self.current_level.next`, and `Level#next` is `acts_as_list`'s `lower_item`, so **on the last level `current_level` becomes `nil` and `finished_at` is set**. A finished passing therefore has no current level and must be handled explicitly.
- `Log` rows are written only in `GamePassingsController#save_log`, i.e. **on answer submission, not on entering a level**. Log is therefore NOT a record of levels visited and must not be used as one — a team on level 3 that has not answered yet has no Log row for level 3.
- `hints_to_show` selects `current_level.hints` by `ready_to_show?`, and depends on `current_level_entered_at`.

- [ ] **Step 1: Write the failing specs, one per matrix row**

```ruby
# append inside describe GameFileAccess
describe "a playing team" do
  before(:each) do
    @team_user = create_user
    # :members, not :user -- create_team takes :captain and :members only, and
    # User belongs_to :team, so the association is set from the team side.
    @team = create_team(:members => [ @team_user ])
    @team_user.reload
    @l1 = create_level(:game => @game, :name => "L1")
    @l2 = create_level(:game => @game, :name => "L2")
    @l3 = create_level(:game => @game, :name => "L3")
    # :level, not :game + :current_level -- create_game_passing derives the
    # game from the level and defaults the run. Passing :game explicitly still
    # calls create_level for the default and leaves a stray level behind.
    @passing = create_game_passing(:level => @l2, :team => @team)
  end

  def attach!(attachable, locale = nil)
    FileAttachment.create!(:game_file => @file, :attachable => attachable, :locale => locale)
  end

  it "permits a file on the level the team is currently on" do
    attach!(@l2)
    expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
  end

  it "permits a file on a level the team has already passed" do
    attach!(@l1)
    expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
  end

  it "REFUSES a file on a level the team has not reached" do
    # The row that matters. A level's photograph is often the puzzle; serving
    # it early hands the next answer to anyone who can guess an id.
    attach!(@l3)
    expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
  end

  it "permits a file on a hint that has already fired" do
    # :delay is in SECONDS, not minutes -- Hint#ready_to_show? compares it
    # directly against `now - current_level_entered_at`.
    hint = create_hint(:level => @l2, :delay => 0)
    @passing.update!(:current_level_entered_at => 1.hour.ago)
    attach!(hint)

    expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
  end

  it "REFUSES a file on a hint that has NOT fired yet" do
    hint = create_hint(:level => @l2, :delay => 1800)
    @passing.update!(:current_level_entered_at => Time.now)
    attach!(hint)

    expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
  end

  it "permits every level once the passing has finished" do
    # current_level is nil at this point -- see the domain note above. Without
    # an explicit branch the position comparison raises NoMethodError on nil
    # and the results screen 500s for every team that completed the game.
    attach!(@l3)
    @passing.update!(:current_level => nil, :finished_at => Time.now)

    expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
  end

  it "permits when ANY of several attachments is visible" do
    attach!(@l1)
    attach!(@l3)

    expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
  end

  it "REFUSES a file attached to nothing" do
    expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
  end

  it "REFUSES a team playing a different game" do
    other_game = create_game(:author => create_user)
    other_level = create_level(:game => other_game)
    create_game_passing(:level => other_level, :team => @team)
    attach!(@l2)

    # The team's passing in the OTHER game must not authorise a file in THIS
    # one. Resolve the passing by game, never "the user's most recent".
    expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
  end
end
```

**Before writing these:** check the real signatures of `create_team`, `create_level`, `create_hint`, and `create_game_passing` in `spec/spec_helpers/fixtures_helper.rb` and adjust the calls to match. The shapes above are indicative; the helper file is authoritative. `create_user` takes **no** arguments.

- [ ] **Step 2: Run and watch every new example fail**

Run: `bundle exec rspec spec/models/game_file_access_spec.rb`
Expected: the 4 author examples pass, the 9 new ones fail.

- [ ] **Step 3: Extend the policy object**

```ruby
  def permitted?
    return false if @user.nil? || @game_file.nil?
    return true  if author_or_superadmin?

    passing = passing_for_game
    return false if passing.nil?

    @game_file.file_attachments.any? { |attachment| visible_to?(passing, attachment) }
  end

  private

  # Resolved BY GAME. "The user's current passing" would authorise a file in
  # game A using the team's progress in game B.
  def passing_for_game
    return nil if game.nil?

    team = @user.team
    return nil if team.nil?

    GamePassing.find_by(:game_id => game.id, :team_id => team.id)
  end

  def visible_to?(passing, attachment)
    case attachment.attachable
    when Level then level_visible?(passing, attachment.attachable)
    when Hint  then hint_visible?(passing, attachment.attachable)
    else false   # fail closed: an attachable type we do not recognise is not visible
    end
  end

  # Finished: every level, because the results and log screens show past
  # levels and the team has completed all of them. Otherwise: the current
  # level and everything at or before it in position order.
  def level_visible?(passing, level)
    return false unless level.game_id == game.id
    return true  if passing.finished?

    current = passing.current_level
    return false if current.nil?

    level.position <= current.position
  end

  # A hint is visible only on the level the team is ON, and only once it has
  # fired. On a PASSED level every hint is visible: the team completed it, so
  # its hints can no longer tell them anything they still need.
  def hint_visible?(passing, hint)
    level = hint.level
    return false if level.nil?
    return false unless level_visible?(passing, level)
    return true  if passing.finished?

    current = passing.current_level
    return true if current.nil? || level.id != current.id   # a passed level

    passing.hints_to_show.include?(hint)
  end
```

- [ ] **Step 4: Run and watch them pass**

Run: `bundle exec rspec spec/models/game_file_access_spec.rb`
Expected: 13 examples, 0 failures.

- [ ] **Step 5: Add the request-spec counterparts for the two denial rows**

The unit specs prove the policy; these prove the controller actually consults it. A policy object nothing calls is a very well-tested no-op.

```ruby
# spec/requests/file_deliveries_spec.rb
describe "a playing team" do
  before(:each) do
    @team_user = create_user
    @team = create_team(:members => [ @team_user ])
    @team_user.reload
    @l1 = create_level(:game => @game, :name => "L1")
    @l2 = create_level(:game => @game, :name => "L2")
    @passing = create_game_passing(:level => @l1, :team => @team)
  end

  it "serves a file on the level the team is on" do
    FileAttachment.create!(:game_file => @file, :attachable => @l1)
    login_as @team_user
    deliver

    expect(response).to have_http_status(:ok)
  end

  it "404s for a file on a level the team has not reached" do
    FileAttachment.create!(:game_file => @file, :attachable => @l2)
    login_as @team_user
    deliver

    expect(response).to have_http_status(:not_found)
  end
end
```

- [ ] **Step 6: Mutate to prove the denials are real**

Change `level.position <= current.position` to `<=` → `>= 0` (i.e. always true) and confirm **"REFUSES a file on a level the team has not reached"** fails. Then change `passing.hints_to_show.include?(hint)` to `true` and confirm **"REFUSES a file on a hint that has NOT fired yet"** fails. Restore both. Paste both failures into your report.

An authorization test that has never been seen to deny is the most expensive kind of green.

- [ ] **Step 7: Full suite, then commit**

```bash
git commit -m "The rows that say no"
```

---

### Task 3: Response headers, and how the bytes actually leave

**Files:**
- Modify: `app/controllers/file_deliveries_controller.rb`
- Modify: `spec/requests/file_deliveries_spec.rb`

**RULING (repository owner, 2026-08-13) — replace `send_data` with `send_file`.**
Task 1 shipped `send_data blob.download`, which loads the whole file into the Ruby heap before a byte is written. With `file_max_megabytes` at 25 and the 1-vCPU host this design keeps citing, several players fetching a large original at once each hold their own 25 MB copy, for as long as the slowest mobile connection takes. The ETag work below turns *repeat* views into 304s but does nothing for the first fetch per client.

Resolve the blob's path on the Disk service and hand it to `send_file`, so the web server streams from disk and the bytes never enter the Ruby heap. This couples the controller to the storage service being local — true today and under the Kamal deployment, and the design's §"Why not Azure Blob" section explains why that is not expected to change. **Record that coupling in a comment**, so a future move to a remote service finds a note rather than a mystery.

Keep the failure behaviour identical: a path that does not exist must still 404, never 500. Task 4 owns the missing-blob case in full, but do not regress it here.

**Requirements, verbatim from design §4:**

| Header | Value | Why |
|---|---|---|
| `Content-Type` | the stored, sniffed `game_file.content_type` | never from the request, never from the filename |
| `X-Content-Type-Options` | `nosniff` | on **every** response |
| `Content-Disposition` | `attachment` for PDF, **always**; `inline` for images | an inline PDF runs in the browser's PDF viewer, a scripting environment we do not control, and §2 cannot neutralise PDF bytes |
| filename encoding | RFC 5987 for non-ASCII | filenames here are Russian more often than not |
| `Cache-Control` | `private, max-age=3600` | **never `public`** — a shared proxy must not serve an authorized response to a different requester |
| `ETag` | derived from `game_file.checksum` **and the variant** | turns repeat views into 304s, which is what stops every image byte re-crossing a Puma worker on a 1-vCPU host |

- [ ] **Step 1: Write the failing specs**

```ruby
describe "response headers" do
  before(:each) { login_as @author }

  it "takes the content type from the stored column, not the filename" do
    # The filename says .png; the sniffed, stored value says jpeg. The stored
    # value wins. A Content-Type derived from an author-supplied filename is
    # how an "image" gets served as text/html.
    @file.update_column(:filename, "photo.png")
    deliver

    expect(response.headers["Content-Type"]).to include("image/jpeg")
  end

  it "sets nosniff on a served file" do
    deliver
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
  end

  it "sets nosniff on a refusal too" do
    get game_file_delivery_path(@game, @file, "nonsense")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
  end

  it "forces a PDF to download" do
    pdf = GameFileUpload.new(@game, fixture_upload("map.pdf"), @author).call
    get game_file_delivery_path(@game, pdf, "original")

    expect(response.headers["Content-Disposition"]).to start_with("attachment")
  end

  it "serves an image inline" do
    deliver
    expect(response.headers["Content-Disposition"]).to start_with("inline")
  end

  it "RFC 5987-encodes a Cyrillic filename" do
    @file.update_column(:filename, "схема.jpg")
    deliver

    expect(response.headers["Content-Disposition"]).to include("filename*=UTF-8''")
  end

  it "marks the response private, never public" do
    # The one header whose mistake is invisible in every local test and
    # catastrophic behind a shared cache: a `public` response to an authorized
    # request can be replayed by the proxy to someone who never passed §4.
    deliver

    expect(response.headers["Cache-Control"]).to include("private")
    expect(response.headers["Cache-Control"]).not_to include("public")
  end

  it "answers 304 to a conditional request carrying the same ETag" do
    deliver
    etag = response.headers["ETag"]

    get game_file_delivery_path(@game, @file, "original"), :headers => { "If-None-Match" => etag }

    expect(response).to have_http_status(:not_modified)
  end

  it "gives a variant a different ETag from the original" do
    # The trap: an ETag built from the checksum alone is identical across
    # variants, so a client holding the 320px thumbnail is told its copy of
    # the full-size original is fresh -- and renders the thumbnail everywhere.
    deliver
    original_etag = response.headers["ETag"]

    get game_file_delivery_path(@game, @file, "thumb")

    expect(response.headers["ETag"]).not_to eq(original_etag)
  end
end
```

- [ ] **Step 2: Run, watch fail, implement**

```ruby
  def deliver(file, variant)
    blob = blob_for(file, variant)
    return head(:not_found) if blob.nil?

    response.headers["X-Content-Type-Options"] = "nosniff"

    # Variant-scoped: a checksum-only ETag is the same for original, web and
    # thumb, so a client holding the thumbnail would be told its copy of the
    # original is still fresh. stale? sets the 304 itself and returns false
    # when the client's copy is current, so the download never happens.
    return unless stale?(:etag => [ file.checksum, variant ], :public => false)

    # AFTER stale?, deliberately: stale?/fresh_when write Cache-Control from
    # their :public argument, so setting it earlier gets overwritten. Verify
    # the header on a real response rather than trusting this ordering --
    # send_data may also touch it.
    response.headers["Cache-Control"] = "private, max-age=3600"

    send_data blob.download, :type => file.content_type,
                             :filename => file.filename,
                             :disposition => disposition_for(file)
  end

  # PDF is always a download. Never inline: the browser's PDF viewer is a
  # scripting environment this app does not control, and unlike an image a
  # PDF cannot be re-encoded into inert bytes by the upload pipeline.
  def disposition_for(file)
    file.content_type == "application/pdf" ? "attachment" : "inline"
  end
```

Set `nosniff` on the 404 paths too — move it to a `before_action` if that reads better, but prove it with a spec either way.

`send_data` handles RFC 5987 encoding of `:filename` itself; the spec verifies that rather than assuming it. If it does not, encode explicitly and say so in the report.

- [ ] **Step 3: Mutate `Cache-Control` to `public, max-age=3600` and confirm a spec fails.** This is the one header whose mistake is invisible in every local test and catastrophic behind a CDN.

- [ ] **Step 4: Full suite, commit**

---

### Task 4: A missing blob is an expected state

Design §7 records this explicitly: **a missing blob must be an expected state, not an exception.** Files can vanish from disk — a restored database with an unrestored volume, an interrupted upload, a `purge_orphans` run against a stale row, a half-finished `azcopy sync` in Phase 4. Every one of those ends with a `GameFile` row whose bytes are gone.

The wrong behaviour is a 500 on the play screen mid-game. The right behaviour is a 404 for that one file, logged, with the rest of the level intact.

**Files:**
- Modify: `app/controllers/file_deliveries_controller.rb`
- Modify: `spec/requests/file_deliveries_spec.rb`

- [ ] **Step 1: Write the failing specs**

```ruby
it "404s, and does not 500, when the blob is gone from disk" do
  login_as @author
  # Delete the stored bytes while leaving every database row intact -- the
  # exact shape of a database restored without its storage volume.
  @file.file.blob.service.delete(@file.file.blob.key)

  deliver

  expect(response).to have_http_status(:not_found)
end

it "404s when the variant's blob is gone but the original survives" do
  login_as @author
  variant = @file.thumb_variant
  variant.image.blob.service.delete(variant.image.blob.key)

  get game_file_delivery_path(@game, @file, "thumb")

  expect(response).to have_http_status(:not_found)
end

it "still serves a healthy file in the same game" do
  # The blast radius test: one dead file must not take the others with it.
  healthy = GameFileUpload.new(@game, fixture_upload("map.pdf"), @author).call
  login_as @author
  @file.file.blob.service.delete(@file.file.blob.key)

  get game_file_delivery_path(@game, healthy, "original")

  expect(response).to have_http_status(:ok)
end
```

- [ ] **Step 2: Implement**

Rescue `ActiveStorage::FileNotFoundError` (and whatever `Disk#download` actually raises for a missing key — **check, do not assume**; on the Disk service a missing file may surface as `Errno::ENOENT`) around the download, log at `warn` with the game id, file id and blob key, and `head :not_found`.

Deliberately narrow: rescue the not-found errors specifically, never `StandardError`. A blanket rescue here would turn a genuine storage misconfiguration into a silent 404 on every file at once, which looks like an authorization bug and would be debugged as one.

- [ ] **Step 3: Verify the rescue is reached, not merely present**

Run the specs with the rescue removed and confirm they fail with a 500 (or the raw exception). A rescue clause for an exception class the code never actually raises is the same green-but-vacuous shape this feature has produced ten times; check that the class you rescue is the class that is thrown, by triggering it once and reading the actual error.

- [ ] **Step 4: Consolidate the matrix**

Add a comment block at the top of `spec/requests/file_deliveries_spec.rb` mapping each example to its row in the design's §4 table, so a reader can check coverage against the contract without cross-referencing prose. If a row has no example, write it now.

- [ ] **Step 5: Full suite, then commit**

```bash
git commit -m "A file that is gone is a 404, not a 500"
```

---

## Self-review notes for the executor

- **The `:constraints` on the route and the `VARIANTS` check in the controller are deliberately redundant.** The route constraint returns a routing 404 before the controller runs; the controller check protects the controller if the route is ever loosened or reached another way. Do not delete either as "duplication" — but do make sure the controller's copy has a test that reaches it, or it is untested duplication rather than defence in depth.
- **Nothing in this phase is user-visible**, so nothing here should add a locale key. If you find yourself writing `t(...)`, stop and reconsider: every failure path is an HTTP status.
- **Phase 3B depends on `GameFileAccess#permitted?`** to decide whether the play screen renders a strip. Keep it callable without a request context.
