# Attachments Phase 3B — picker, play screen, live hints

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the feature real — an author picks files from a gallery while editing a level or hint, and a playing team sees them on the play screen, including on hints that unlock mid-level.

**Architecture:** Attachments are assigned through a locale-aware setter on a shared concern, so editing one language tab never disturbs another's. The play screen renders a strip server-side for the level and for already-fired hints; hints that unlock *after* page load arrive through the existing JSON poller, whose payload gains an attachments array that the JavaScript turns into `<img>` elements built with `createElement`/`setAttribute` — never an HTML string.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, no Turbo, no rails-ujs, no asset pipeline. Plain forms, plain `<a>`, one hand-written jQuery file.

## Global Constraints

- **The 58 inherited `features/**/*.feature` files are FROZEN** — 232 scenarios / 2342 steps, the Merb contract. Never edit one. **Port-authored feature files may be added and edited** under PR #90's provenance clarification; `features/games/game-files.feature` is port-authored.
- **This phase is the highest-risk one in the programme for the frozen suite.** It edits the level and hint edit forms and the play screen — exactly where `features/levels/*`, `features/hints/*` and the game-passing features drive. Run the full suite at the end of EVERY task, and verify the inherited contract by exclusion, never by subtraction:
  `bundle exec cucumber --exclude 'game-files\.feature'` → must stay **232 scenarios / 2342 steps**.
- **Platform chrome is translated; author-written game content is NEVER run through `t()`.** Filenames, level names and hint text are author content. Running them through `t()` prints `translation missing:` into a live game.
- **Seven locales** (`ru en uk ka tr be pl`), `ru` default, fallbacks to `ru`; the test env raises on missing translations. Every new user-facing string goes in all seven. **Any new string on the PLAY screen must also be added to `spec/i18n_play_screen_spec.rb`'s pinned list** — a subset-of-`ru` locale passes every other i18n check while silently rendering Russian mid-game.
- **Turkish and Georgian:** never let a case suffix land on an interpolated value; put it on a common noun. Prefer a count over a name.
- Hash rockets (`:key => value`) throughout. Comments and identifiers in English.
- The repository is PUBLIC: no secrets, tokens, or absolute developer paths.
- **Never add a Ruby-side `.upcase`/`.downcase` to user-facing text** — it is locale-blind and turns Turkish `i` into `I` rather than `İ`.

## What Phase 3A left, and must not be broken

- `GameFileAccess.new(user, game_file).permitted?` — the §4 matrix. The class comment says the play screen should call it BEFORE rendering, so a view never emits an `<img>` the delivery route will 404.
- `GET /games/:game_id/files/:id/:variant` (`game_file_delivery_path`), variant ∈ `original|web|thumb`.
- **Design §3 invariant I1: a GET must never allocate disk.** `GameFile#existing_web_variant`/`#existing_thumb_variant` are the read-only accessors; `web_variant`/`thumb_variant` GENERATE and must never be reached from a render or a request path.
- **A `GameFileAccess` performance note left explicitly for this phase:** `.includes(:attachable)` inside `permitted?` DISCARDS an already-loaded association cache, so calling it per file on a page that preloaded attachments costs a query per file. Read the preloaded association instead of re-scoping it.

## File Structure

| File | Responsibility |
|---|---|
| `app/models/concerns/file_attachable.rb` (create) | The two associations plus the locale-aware setter, shared by Level and Hint |
| `app/models/level.rb`, `app/models/hint.rb` (modify) | Include the concern, drop the duplicated associations |
| `app/views/game_files/_file_table.html.erb` (modify) | Real thumbnails in both modes |
| `app/views/levels/edit.html.erb`, `app/views/hints/_form.html.erb` (modify) | Render the picker |
| `app/controllers/levels_controller.rb`, `hints_controller.rb` (modify) | Permit and apply the picked ids |
| `app/views/shared/_attachment_strip.html.erb` (create) | One strip, used by the level and by each hint |
| `app/views/game_passings/show_current_level.html.erb` (modify) | Render the strips |
| `app/controllers/game_passings_controller.rb` (modify) | `get_current_level_tip` payload gains attachments |
| `public/javascripts/level_hint_updater.js` (modify) | Build `<img>` nodes for a live hint |
| `app/models/game_file_access.rb` (modify) | Accept a run, closing 3A's open question |

---

### Task 1: Locale-aware attachment assignment

No UI. The model layer the picker will drive.

**Files:**
- Create: `app/models/concerns/file_attachable.rb`
- Modify: `app/models/level.rb` (lines 18-20), `app/models/hint.rb` (lines 12-14)
- Create: `spec/models/file_attachable_spec.rb`

**Interfaces produced:** `#replace_attached_files(game_file_ids, locale)` on both `Level` and `Hint`; `#attached_files_for(locale)` returning the ordered `GameFile`s a player in that locale should see.

**The rule this task exists to enforce:** the primary-locale tab manages the **language-neutral** slot (`locale: nil`, shown to every player); a non-primary tab manages that language's own slot. `FileAttachment.for_locale` already unions the two, and `acts_as_list` is scoped to `[attachable_type, attachable_id, locale]`, so they are two independently ordered strips. **Replacing one slot must leave every other slot untouched** — the failure mode is an author editing the English tab and silently deleting the photographs every player was seeing.

- [ ] **Step 1: Write the failing spec**

```ruby
require "rails_helper"

describe FileAttachable do
  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @level  = create_level(:game => @game)
    @a = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
    @b = GameFileUpload.new(@game, fixture_upload("map.pdf"), @author).call
  end

  it "attaches files to the neutral slot" do
    @level.replace_attached_files([ @a.id ], nil)

    expect(@level.file_attachments.reload.map(&:game_file_id)).to eq([ @a.id ])
    expect(@level.file_attachments.first.locale).to be_nil
  end

  it "does NOT disturb the neutral slot when replacing a language slot" do
    # The failure this whole task exists to prevent: an author opens the
    # English tab, picks one file, saves, and every player of every language
    # silently loses the photographs that were on the neutral strip.
    @level.replace_attached_files([ @a.id ], nil)
    @level.replace_attached_files([ @b.id ], "en")

    neutral = @level.file_attachments.reload.where(:locale => nil)
    english = @level.file_attachments.where(:locale => "en")

    expect(neutral.map(&:game_file_id)).to eq([ @a.id ])
    expect(english.map(&:game_file_id)).to eq([ @b.id ])
  end

  it "removes what is no longer picked, within that slot only" do
    @level.replace_attached_files([ @a.id, @b.id ], nil)
    @level.replace_attached_files([ @b.id ], nil)

    expect(@level.file_attachments.reload.map(&:game_file_id)).to eq([ @b.id ])
  end

  it "REFUSES a file from another game, without raising" do
    # The form posts ids. An author can edit them, and FileAttachment's own
    # validator fails closed -- but create! would raise, turning a hostile
    # id into a 500. Filter to the owning game's library first so the row is
    # never attempted.
    other = GameFileUpload.new(create_game(:author => create_user),
                               fixture_upload("photo.jpg"), @author).call

    expect { @level.replace_attached_files([ other.id ], nil) }.not_to raise_error
    expect(@level.file_attachments.reload).to be_empty
  end

  it "works the same on a Hint" do
    hint = create_hint(:level => @level)
    hint.replace_attached_files([ @a.id ], nil)

    expect(hint.file_attachments.reload.map(&:game_file_id)).to eq([ @a.id ])
  end

  it "returns neutral plus the player's language, in position order" do
    @level.replace_attached_files([ @a.id ], nil)
    @level.replace_attached_files([ @b.id ], "en")

    expect(@level.attached_files_for("en").map(&:id)).to match_array([ @a.id, @b.id ])
    expect(@level.attached_files_for("ru").map(&:id)).to eq([ @a.id ])
  end
end
```

- [ ] **Step 2: Run it, watch it fail** (`uninitialized constant FileAttachable`).

- [ ] **Step 3: Write the concern**

```ruby
# -*- encoding : utf-8 -*-
#
# Shared by Level and Hint: both own an ordered list of GameFiles, per locale.
module FileAttachable
  extend ActiveSupport::Concern

  included do
    has_many :file_attachments, -> { order(:position) },
             :as => :attachable, :dependent => :destroy
    has_many :game_files, :through => :file_attachments
  end

  # Replace ONE locale's slot, leaving every other slot alone.
  #
  # nil is a real value here, not "unset": it is the language-neutral strip
  # every player sees. `locale.presence` folds "" (what a form sends for the
  # primary tab) onto it.
  def replace_attached_files(game_file_ids, locale)
    slot = locale.presence
    wanted = owning_game ? owning_game.game_files.where(:id => Array(game_file_ids)).pluck(:id) : []

    transaction do
      current = file_attachments.where(:locale => slot)
      current.where.not(:game_file_id => wanted).destroy_all

      already = file_attachments.where(:locale => slot).pluck(:game_file_id)
      (wanted - already).each do |id|
        file_attachments.create!(:game_file_id => id, :locale => slot)
      end
    end

    file_attachments.reset
  end

  # What a player reading `locale` should see: the neutral strip plus their
  # own language's, in position order.
  def attached_files_for(locale)
    file_attachments.for_locale(locale).includes(:game_file).map(&:game_file)
  end

  private

  # Level has a game; a Hint reaches it through its level. Both can be nil on
  # an unsaved or malformed record, and `wanted` above degrades to [] there.
  def owning_game
    case self
    when Level then game
    when Hint  then level&.game
    end
  end
end
```

**Note on `wanted`:** filtering the posted ids against `owning_game.game_files` is what stops a hand-edited `game_file_ids[]` from either raising or attaching a foreign game's file. `FileAttachment#file_belongs_to_the_same_game` remains as the second guard — do not remove it.

- [ ] **Step 4: Include it, removing the now-duplicated associations from both models.** `Level` currently declares them at lines 18-20 and `Hint` at 12-14. Delete those and `include FileAttachable`. Check nothing else relied on a different `has_many` option.

- [ ] **Step 5: Run the spec, then the full suite.** `bundle exec rspec` and `bundle exec cucumber`, plus the `--exclude` run for the inherited contract.

- [ ] **Step 6: Prove the slot isolation by mutation.** Change `current.where.not(...)` to drop the `:locale => slot` scoping (i.e. delete across all slots) and confirm "does NOT disturb the neutral slot" fails. Paste it.

- [ ] **Step 7: Commit.**

---

### Task 2: The picker, and real thumbnails

**Files:**
- Modify: `app/views/game_files/_file_table.html.erb`
- Modify: `app/views/levels/edit.html.erb`, `app/views/hints/_form.html.erb`
- Modify: `app/controllers/levels_controller.rb`, `app/controllers/hints_controller.rb`
- Modify: all seven `config/locales/*.yml`
- Create: `spec/requests/attachment_picker_spec.rb`

**Two things at once, both about the table:** the `:picker` mode already exists (Phase 2B built it), and now that a delivery route exists the `file-thumb` cell can stop rendering the literal strings `"PDF"`/`"IMG"` and render an actual `<img>` at the `thumb` variant. A PDF keeps a generic icon — it has no thumbnail (`thumb_variant` is nil for PDFs, by design).

**The picker is rendered inside the existing form**, below the text fields, in both `levels/edit` and `hints/_form`. It must:
- post `level[game_file_ids][]` / `hint[game_file_ids][]`
- carry the ACTIVE TAB's locale, so the controller knows which slot to replace
- pre-check the files already attached to that slot
- list the whole game library, not just the attached files — it is a gallery

**Checkbox state is the trap.** `_file_table`'s picker branch currently hard-codes `false` for the checked argument. It needs the actual state, or an author saves and silently detaches everything they did not re-tick.

**Strong params.** `level_params` permits a fixed list; add `:game_file_ids => []`. An array param needs `[]`, not a scalar. Remember `level_attributes` builds a hash for `update` — `game_file_ids` must NOT go into `update`, because the through-association's own `game_file_ids=` writes rows with no locale and would defeat Task 1 entirely. Delete it from the attributes hash and apply it via `replace_attached_files` after a successful save.

- [ ] **Step 1: Write failing request specs** — an author picks two files on the primary tab and both attach to the neutral slot; picking on a non-primary tab writes that locale's slot and leaves the neutral one intact; unticking removes; a non-author gets the existing refusal; and the pre-checked state round-trips (save, reload the form, the boxes are still ticked).

- [ ] **Step 2: Run, watch fail, implement.**

- [ ] **Step 3: i18n.** Any new label (a picker heading, an "no files in this game yet" empty state) in all seven locales. These are author-facing, not play-screen, so `spec/i18n_play_screen_spec.rb` does not apply — but `spec/i18n_spec.rb`'s exact `ru`↔`en` parity does.

- [ ] **Step 4: Run the full suite, and the inherited-contract exclusion run.** This task edits the level and hint edit forms. `features/levels/*.feature` and `features/hints/*.feature` drive exactly here. If the inherited count moves, STOP and report — do not adjust a feature file.

- [ ] **Step 5: Commit.**

---

### Task 3: The play-screen strip

**Files:**
- Create: `app/views/shared/_attachment_strip.html.erb`
- Modify: `app/views/game_passings/show_current_level.html.erb`
- Modify: `app/controllers/game_passings_controller.rb` (preloading only)
- Modify: all seven `config/locales/*.yml`, and `spec/i18n_play_screen_spec.rb`
- Create: `spec/views/attachment_strip_spec.rb`

The strip goes **below the task text** for the level, and inside each fired hint's `fieldset`. Design decision already taken and recorded: *"Renderer never parses author text, so the app's absolute HTML-escaping guarantee is untouched. No new injection surface at all."* Do not put images inside author text.

Each image links to the `original` variant and displays the `web` variant; a PDF renders as a link with a generic icon, never an `<img>`.

**Authorization before rendering.** The class comment on `GameFileAccess` says the play screen must ask before emitting a tag, so a view never renders an `<img>` the delivery route will 404. But **read the performance note in Global Constraints**: `permitted?` re-queries `file_attachments` even when preloaded. Preload what the strip needs and avoid a query per file; say in your report what the page costs in queries with and without your preloading.

**Any new string here is a PLAY-SCREEN string** — all seven locales AND `spec/i18n_play_screen_spec.rb`'s pinned list. A locale missing from that list renders Russian to a team mid-race while every other i18n check passes.

- [ ] **Step 1: Write the failing view spec** — the strip renders an `img` whose `src` is the delivery path at the `web` variant for an attached image; a PDF renders an `a`, not an `img`; a file the requester may not see renders nothing; an empty list renders no empty container.
- [ ] **Step 2: Run, watch fail, implement.**
- [ ] **Step 3: Alt text.** Use the filename — author content, escaped by ERB, never through `t()`.
- [ ] **Step 4: Full suite + exclusion run.** The play screen is where the game-passing features drive. Same rule as Task 2: if the inherited count moves, stop.
- [ ] **Step 5: Commit.**

---

### Task 4: Live hints

The security-sensitive task of this phase.

**Files:**
- Modify: `app/controllers/game_passings_controller.rb` (`get_current_level_tip`)
- Modify: `public/javascripts/level_hint_updater.js`
- Create: `spec/requests/live_hint_attachments_spec.rb`

**Read `public/javascripts/level_hint_updater.js`'s `appendHint` comment before writing a line.** It records that jQuery `.append()` with a string parses it as markup, and that concatenating there *"made every hint a stored-XSS vector against every playing team"*. The current code builds nodes with `document.createTextNode`. **That property must survive this task.**

So: the JSON payload gains an array of `{url, alt}` objects, and the JavaScript builds each image with `document.createElement("img")` and `setAttribute`. **No `innerHTML`, no jQuery `.append(string)`, no string concatenation producing markup.** The `url` is generated server-side by the Rails path helper and is same-origin; `alt` is an author-supplied filename and must reach the DOM only through `setAttribute`/`textContent`, which do not parse.

**Authorization still applies.** The payload must only include files the requesting team may see — the same `GameFileAccess` question, for the hint that just fired. A hint's attachments become visible exactly when the hint does.

- [ ] **Step 1: Write failing request specs on the JSON** — the payload includes the fired hint's attachments; it does NOT include an unfired hint's; it does not include a file from another game; and the urls are the delivery route's paths at the `web` variant.
- [ ] **Step 2: Run, watch fail, implement the controller half.**
- [ ] **Step 3: The JavaScript.** Extend `appendHint` to take the attachments array and build nodes. Keep the existing `createTextNode` for the text.
- [ ] **Step 4: Prove the XSS property survived.** A filename of `"><img src=x onerror=alert(1)>.jpg` must reach the page as text/attribute content, never as markup. The acceptance suite cannot execute JavaScript, so assert this at the JSON layer (the payload carries the raw filename, correctly JSON-escaped) AND by reading the JS for `innerHTML`/string concatenation. Say explicitly in your report which parts you could and could not verify mechanically — do not claim browser-level proof this project's tooling cannot produce.
- [ ] **Step 5: The hardcoded Russian in the JS.** `appendHint` sets `legend.textContent = "Подсказка #" + hintNum` — a literal, while the server-rendered path uses `t("game_passings.show_current_level.hint_label")`. A non-Russian player already sees this. Fix it by passing the label in the JSON payload (the server knows the content locale) rather than hardcoding another language. **This is a pre-existing bug, in scope because you are editing this exact function** — note it as such in the commit.
- [ ] **Step 6: Full suite + exclusion run. Commit.**

---

### Task 5: Close 3A's open question — past-run screens

**Files:**
- Modify: `app/models/game_file_access.rb`
- Modify: `app/controllers/file_deliveries_controller.rb`
- Modify: `docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md` (§4)
- Modify: `spec/models/game_file_access_spec.rb`, `spec/requests/file_deliveries_spec.rb`

Phase 3A shipped with a known false deny, recorded in design §4: `passing_for_game` resolves only `game.current_run`, so once a later run opens, every attachment on a team's own **past-run** log or results screen 404s permanently. 3A left it because resolving across all runs would re-open a Critical it had just closed — the library is per-game, progress is per-run, and authors edit content between runs.

3B is the phase that renders those screens, so it decides. **The approach §4 records:** resolve the SPECIFIC run the screen is already showing (`LogsController#find_run` and `GamePassingsController#find_run` both already resolve a `?run=N` into `@run`), rather than asking `GameFileAccess` to infer "current" from the team alone.

That means the delivery route needs to know which run the requester is viewing. **Do not take it from an unvalidated parameter and trust it** — the requester must have a passing in the run they name, and the answer must be that passing's progress. A team naming a run it never played gets nothing new; a team naming run 1 gets run 1's progress, which is exactly what it earned.

- [ ] **Step 1: Write the failing specs, including the attack.** A team that finished run 1 and is on level 1 of run 2: naming run 1 permits run 1's passed levels; naming run 2 permits only level 1; **naming run 1 must NOT permit a level it never reached in run 1**; naming a run it has no passing in permits nothing; omitting the run keeps today's current-run behaviour.
- [ ] **Step 2: Run, watch fail, implement.**
- [ ] **Step 3: Mutate.** Make the run parameter trusted without checking the team has a passing in it, and confirm a spec fails. This is the guard that keeps the Critical closed.
- [ ] **Step 4: Update design §4** — replace the "Open question for Phase 3B" block with what was decided and why.
- [ ] **Step 5: Full suite + exclusion run. Commit.**

---

## Self-review notes for the executor

- **The riskiest thing in this phase is not a security hole, it is the frozen suite.** Tasks 2 and 3 edit files the inherited features drive through. Adding a form field or a `<div>` should not disturb them — but that is a prediction, not a fact, and it is why every task ends with the exclusion run rather than only the full one.
- **Do not use the through-association's generated `game_file_ids=`.** It writes rows with no locale and silently defeats Task 1. Task 2's controller must delete that key from the attributes hash.
- **Nothing in this phase may call `web_variant`/`thumb_variant`** (they generate). Use `existing_*`. A render path that allocates disk breaks invariant I1, whose consequence is the play screen failing for a team mid-race on a full disk.
