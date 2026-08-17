# Translating large games — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin translate a game of any realistic size in one press, and give the panel that starts it a two-column layout.

**Architecture:** No new tables, states or background machinery. Three independent changes: a stylesheet rule for the panel; an estimator rewritten from O(units × locales) API round trips to O(locales + k); and one `Setting` default raised now that the estimator no longer collapses on big input.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec, Cucumber (Russian Gherkin), plain CSS in `public/stylesheets/`, Anthropic Ruby SDK behind `Translation::Client`.

**Spec:** `docs/superpowers/specs/2026-08-17-translation-large-games-design.md`

## Global Constraints

- Ruby is **3.3.12** via rbenv and is **not on `PATH` in non-login shells**. Every command below assumes you have first run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit a `features/**/*.feature` file.** No task here touches one. If a feature test fails, the implementation is wrong.
- Hash rockets (`:key => value`) throughout, including for symbol keys — match the surrounding file.
- Code, identifiers and comments in **English**; user-facing strings in Russian via `t()`. No task here adds a user-facing string.
- Object factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb` (`create_user`, `create_game`, `create_level`, `create_quiz_level`, `create_question`, `create_option`). **`create_user` takes no arguments.** Do not introduce FactoryBot.
- `spec/layout` is **excluded** from an ordinary `bundle exec rspec` (`config.filter_run_excluding :layout` in `spec/rails_helper.rb`). Run it with `bin/measure-play-screen` or `LAYOUT_SPECS=1 bundle exec rspec spec/layout`. It needs `chrome-headless-shell` (`npx playwright install chromium`); the full `chromium-*` build is **not** a substitute — it clamps windows to 500px wide.
- Layout specs **raise** rather than `skip` when the browser is missing. Never convert one to a skip.
- **Task order matters across PR 2:** Tasks 3 and 4 (the estimator) must land **before** Task 5 (the cap). Raising the cap first exposes the unbounded pre-flight and turns a clean refusal into a hung request.

---

## PR 1 — the panel

### Task 1: Extract the layout measurement harness

The browser-driving helper currently lives inside `spec/layout/play_screen_layout_spec.rb` as private methods of one `describe` block. Task 2 needs the same helper for a second screen. Extract first, with the existing suite green before and after, so a later failure is unambiguously about the panel.

**Files:**
- Create: `spec/support/layout_measurement.rb`
- Modify: `spec/layout/play_screen_layout_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `LayoutMeasurement`, a module to `include` in a layout spec, exposing
  - `chrome` → `String` path to the browser binary, raising if absent
  - `measure(html, width, height, script, tmp_name: "layout-measure.html")` → `Hash` parsed from the probe's `RESULT` object
  - `LayoutMeasurement::CHROME_GLOB` → `String`

- [ ] **Step 1: Confirm the existing layout suite is green before touching it**

Run: `bin/measure-play-screen`
Expected: `17 examples, 0 failures`. If it is not green, stop — do not start a refactor on a red suite.

**Note on this number.** It is 17 on a branch cut from `origin/master` at `8ca9b5c`, and 20 once PR #110 (play-screen theme/language controls) merges, which adds three examples to the same file. Whichever it is, what matters is that Step 4 reports **the same count as Step 1** — an extraction must not change it. Substitute accordingly below.

- [ ] **Step 2: Create the support module**

Create `spec/support/layout_measurement.rb`. This is a straight move of the two methods, plus one new parameter (`tmp_name`) so two specs cannot fight over one scratch file. The comments move with the code — they record why each line exists and are not decoration.

```ruby
# spec/support/layout_measurement.rb
#
# Drives a real headless browser at a fixed viewport and returns whatever the
# probe script assigns to RESULT. Extracted from play_screen_layout_spec.rb so
# more than one screen can be measured; the reasoning in the comments below is
# load-bearing and moved with it.
require "json"
require "shellwords"

module LayoutMeasurement
  CHROME_GLOB = File.expand_path(
    "~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell"
  )

  # The full chromium build clamps windows to 500px wide, which silently turns
  # every phone measurement into a 500px one; headless_shell honours narrow
  # sizes. Raise rather than skip: a measurement that quietly did not happen is
  # worse than no measurement, because it reports as a pass.
  def chrome
    @chrome ||= Dir.glob(CHROME_GLOB).max ||
      raise(<<~MSG)
        No chrome-headless-shell found at #{CHROME_GLOB}

        Install it with:  npx playwright install chromium
        The full `chromium-*/chrome-linux64/chrome` build is NOT a substitute --
        it clamps the window to 500px wide, so every phone size measures as 500.
      MSG
  end

  # Rewrites the stylesheet links AND the attachment images to absolute file://
  # paths so the page can be opened straight off disk. A static HTTP server
  # would work too; this removes a moving part (a port, a process to reap) from
  # something that has to be trustworthy to be worth running.
  #
  # The images matter and were missed the first time round. Left as
  # `/games/1/files/1/web`, they resolve against file:// to `file:///games/...`
  # and never load -- so this harness measured two BROKEN images while claiming
  # to measure photographs, which is the entire content class it exists for.
  def measure(html, width, height, script, tmp_name: "layout-measure.html")
    page = html.gsub(%r{href="/(stylesheets/[^"]+)"}) do
      %(href="file://#{Rails.root.join('public', Regexp.last_match(1))}")
    end
    # The delivery route is dynamic (variant, authorization, streaming); none of
    # that is layout. What layout needs is a real decoded image of a real size,
    # which is the fixture the upload was built from in the first place.
    photo = Rails.root.join("spec/fixtures/files/photo.jpg")
    page = page.gsub(%r{src="/games/\d+/files/\d+/\w+"}, %(src="file://#{photo}"))
    page = page.sub("</body>", <<~PROBE + "</body>")
      <script>
      window.addEventListener("load", function () {
        #{script}
        var pre = document.createElement("pre");
        pre.textContent = "RESULT=" + JSON.stringify(RESULT);
        document.body.appendChild(pre);
      });
      </script>
    PROBE

    file = Rails.root.join("tmp", tmp_name)
    FileUtils.mkdir_p(file.dirname)
    File.write(file, page)

    dom = `#{Shellwords.join([
      chrome, "--no-sandbox", "--hide-scrollbars", "--allow-file-access-from-files",
      "--window-size=#{width},#{height}", "--virtual-time-budget=4000",
      "--dump-dom", "file://#{file}"
    ])} 2>/dev/null`

    # tail: the probe's own source contains the literal "RESULT=" too, and it
    # is in the dumped DOM ahead of the value.
    json = dom.scan(/RESULT=(\{.*?\})<\/pre>/m).last&.first ||
      raise("the browser produced no measurement; dumped DOM was:\n#{dom[0, 2000]}")
    JSON.parse(json)
  end
end
```

- [ ] **Step 3: Point the play-screen spec at the module**

In `spec/layout/play_screen_layout_spec.rb`:

1. Add near the other requires at the top: `require_relative "../support/layout_measurement"`
2. Delete `CHROME_GLOB` from the `PlayScreenLayoutHarness` module (keep `VIEWPORTS`).
3. Delete the `def chrome` and `def measure` method bodies from the `describe` block.
4. Add as the first line inside the `describe` block: `include LayoutMeasurement`
5. Change the `let(:m)` call to name its scratch file:

```ruby
      let(:m) { measure(page_html, width, height, PROBE_SCRIPT, :tmp_name => "play-screen-measure.html") }
```

- [ ] **Step 4: Run the layout suite to verify the extraction changed nothing**

Run: `bin/measure-play-screen`
Expected: `0 failures` and **the same example count Step 1 reported** (17 on this branch, 20 after PR #110 merges). A changed count means the extraction dropped or duplicated examples.

- [ ] **Step 5: Run the ordinary suite, because this file is loaded even when filtered out**

Run: `bundle exec rspec`
Expected: `0 failures`. `spec/layout/*.rb` is *loaded* on every run and only its examples are filtered, so a `require_relative` typo or a constant collision shows up here.

- [ ] **Step 6: Commit**

```bash
git add spec/support/layout_measurement.rb spec/layout/play_screen_layout_spec.rb
git commit -m "Extract the layout measurement harness"
```

---

### Task 2: Two-column translate panel

**Files:**
- Modify: `public/stylesheets/screens.css` (append near the existing `.missing-translations` rules, ~line 189)
- Create: `spec/layout/translate_panel_layout_spec.rb`

**Interfaces:**
- Consumes: `LayoutMeasurement` from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing layout spec**

Create `spec/layout/translate_panel_layout_spec.rb`. The markup already exists at `app/views/games/edit.html.erb:89-99`; only the CSS is missing.

```ruby
require "rails_helper"
require_relative "../support/layout_measurement"

# The AI-translation panel on the game edit screen, measured in a real browser.
#
# WHY: neither suite can see this. Capybara's rack_test driver parses no
# stylesheet, and a request spec sees markup only -- so "the buttons are in two
# columns" is a claim no ordinary test in this repository can make or refute.
# The panel shipped with NO css rule for either of its classes and rendered as a
# staircase for weeks without a single test noticing.
describe "the translate panel, measured", :layout, type: :request do
  include LayoutMeasurement

  # Superadmin-only AND hidden without an API key, so both have to be true
  # before there is anything on the page to measure at all. The key is stubbed
  # at Client.configured? -- the same seam spec/requests/translation_runs_spec.rb
  # uses -- rather than by setting ENV, so no example depends on the developer's
  # environment.
  before { allow(Translation::Client).to receive(:configured?).and_return(true) }

  let(:page_html) do
    admin = create_user
    admin.update!(:is_superadmin => true)
    game = create_game(:author => admin, :name => "Викторина",
                       :primary_locale => "ru", :available_locale_list => %w[ru])

    put login_path, :params => { :email => admin.email, :password => "1234" }
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("translate-locales")
    response.body
  end

  PANEL_PROBE = <<~JS
    var buttons = Array.prototype.slice.call(
      document.querySelectorAll(".translate-locales button")
    );
    var lefts = buttons.map(function (b) {
      return Math.round(b.getBoundingClientRect().left);
    });
    var RESULT = {
      count: buttons.length,
      distinctLefts: lefts.filter(function (v, i, a) { return a.indexOf(v) === i; }).length,
      hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      // display: contents must not remove the list from the accessibility tree.
      // Verified rather than assumed: Chrome and Safari used to drop list
      // semantics for a display:contents <li>, which would make this fix trade
      // a layout bug for an accessibility one.
      listRole: (function () {
        var ul = document.querySelector(".translate-locales");
        return ul ? (ul.computedRole || "unknown") : "ABSENT";
      })()
    };
  JS

  { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
    context "at #{width}x#{height} -- #{name}" do
      let(:m) { measure(page_html, width, height, PANEL_PROBE, :tmp_name => "translate-panel-measure.html") }

      # One button per non-primary locale: seven registered, minus ru.
      it "renders a button for every target locale" do
        expect(m["count"]).to eq(6)
      end

      # THE assertion. Every button starting at the same x is what "two
      # columns" means; a staircase is six different values.
      it "starts every button at the same x" do
        expect(m["distinctLefts"]).to eq(1)
      end

      it "does not overflow sideways" do
        expect(m["hOverflow"]).to eq(0)
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout/translate_panel_layout_spec.rb`
Expected: FAIL on "starts every button at the same x" — `distinctLefts` will be 6, one per row, because no CSS exists yet. The `count` and `hOverflow` examples may already pass; that is fine and expected.

If instead it fails on `expect(response.body).to include("translate-locales")`, the panel is not rendering at all: the `before` block's `configured?` stub or the `is_superadmin` update is not taking effect, since `app/views/games/edit.html.erb:86` requires both.

- [ ] **Step 3: Add the CSS**

Append to `public/stylesheets/screens.css`, immediately after the existing `.missing-translations` rules so the two translation-related panels sit together:

```css
/* The AI-translation panel on the game edit screen. It shipped with no rule at
   all, so a label followed by a button_to (which renders its own <form>) laid
   out as a staircase: each row's button started wherever that row's locale name
   happened to end.

   The grid is on the UL and each LI is display: contents, which promotes the
   label and the form into items of the parent grid. That is what aligns the
   buttons ACROSS rows -- a grid on each <li> individually cannot, because no
   li knows how wide its neighbours' labels are, and subgrid is the only other
   tool for it.

   max-content, not a fixed width: the label column has to fit the widest
   endonym, and which one that is depends on the registered locale set and the
   font. Беларуская and ქართული are the long ones today; hard-coding a rem
   value would break the day an eighth locale is registered. */
.translate-locales {
  display: grid;
  grid-template-columns: max-content max-content;
  gap: var(--space-2) var(--space-3);
  align-items: center;
  margin-bottom: var(--space-3);
}

.translate-locales li { display: contents; }

/* button_to renders a <form>, and a form carries default margin in some UA
   stylesheets. As a grid item that margin becomes visible column padding. */
.translate-locales form { margin: 0; }

.translate-panel { margin-top: var(--space-5); }
.translate-panel h3 { margin-bottom: var(--space-2); }
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout/translate_panel_layout_spec.rb`
Expected: `6 examples, 0 failures`.

**If `distinctLefts` is still 6**, `display: contents` is not being honoured — check that no other rule sets `display` on `.translate-locales li`.

**If the accessibility check reports something other than a list role**, do not ship `display: contents`. Fall back to changing the markup in `app/views/games/edit.html.erb` from `<ul>`/`<li>` to `<div class="translate-locales">` with each pair as two direct children, drop the `li { display: contents }` rule, and note in the CSS comment why the list was abandoned. The spec's `listRole` value is informational, not asserted — read it in the output.

- [ ] **Step 5: Run the whole layout suite and the ordinary suite**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout`
Expected: `26 examples, 0 failures` (20 from the play screen, 6 here).

Run: `bundle exec rspec`
Expected: `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add public/stylesheets/screens.css spec/layout/translate_panel_layout_spec.rb
git commit -m "Lay the translate panel out in two columns"
```

---

## PR 2 — the wall and the pre-flight

### Task 3: Constant-cost pre-flight estimate

Replaces the per-unit-per-locale `count_tokens` loop with prefix + bulk arithmetic. **This must land before Task 5.**

**Files:**
- Modify: `app/services/translation/unit.rb`
- Modify: `app/services/translation/runner.rb:69-79` (the current `estimate_input_tokens`)
- Create: `spec/services/translation/estimate_spec.rb`

**Interfaces:**
- Consumes: `Translation::Unit.new(key, fields)`, `Translation::Client#count_input_tokens(unit:, locale:)`.
- Produces:
  - `Translation::Unit.raw(key, text)` → `Unit` whose `source_text` is `text`
  - `Translation::Runner.estimate_input_tokens(game, locales, client: nil)` → `Integer` (unchanged signature)
  - `Translation::Runner::BASELINE_SOURCE` → `String`

- [ ] **Step 1: Write the failing spec**

Create `spec/services/translation/estimate_spec.rb`:

```ruby
require "rails_helper"

# The pre-flight estimate, which must cost a number of API round trips that does
# NOT grow with the size of the game.
#
# It used to be one count_tokens call per unit per locale, synchronously inside
# the POST that renders the confirmation screen: 71 calls for a 70-level quiz at
# one language, ~426 at six. The 400-field cap was the only thing keeping that
# from being reached at all.
describe Translation::Runner, ".estimate_input_tokens" do
  # Records every call so the COUNT can be asserted. A spec that checked only
  # the returned number would pass just as happily with the old O(units x
  # locales) loop still in place, which is the whole bug.
  class CountingClient
    attr_reader :calls

    # Returns BASELINE for a baseline-sized source and BASELINE + SOURCES for
    # the bulk call, which is exactly the shape the arithmetic assumes.
    BASELINE = 40
    SOURCES  = 500

    def initialize
      @calls = []
    end

    def count_input_tokens(unit:, locale:)
      @calls << [ unit.key, locale, unit.source_text.length ]
      unit.key == "estimate:baseline" ? BASELINE : BASELINE + SOURCES
    end
  end

  def game_with(levels:)
    game = create_game(:primary_locale => "ru", :available_locale_list => %w[ru])
    levels.times { |i| create_level(:game => game, :name => "Уровень #{i}", :text => "Текст #{i}") }
    game
  end

  it "issues one baseline call per locale plus one bulk call" do
    client = CountingClient.new
    described_class.estimate_input_tokens(game_with(:levels => 5), %w[en pl], :client => client)

    expect(client.calls.size).to eq(3)
    expect(client.calls.map(&:first)).to eq(
      [ "estimate:baseline", "estimate:baseline", "estimate:bulk" ]
    )
  end

  # THE assertion. The old implementation's call count was a function of level
  # count; the new one's must not be.
  it "does not make more calls when the game gets bigger" do
    small = CountingClient.new
    big   = CountingClient.new

    described_class.estimate_input_tokens(game_with(:levels => 3),  %w[en], :client => small)
    described_class.estimate_input_tokens(game_with(:levels => 30), %w[en], :client => big)

    expect(big.calls.size).to eq(small.calls.size)
  end

  # total = n_units x SUM(baselines) + n_locales x SUM(source tokens)
  #
  # 6 units = 1 game header + 5 levels. The header unit always exists here
  # because build_game sets BOTH name and description, so the game's own two
  # translatable fields are always in the work-list; a game with neither would
  # produce 5 units and this total would be 400 + 1000.
  #
  # 6 x (40 + 40) + 2 x 500 = 480 + 1000 = 1480
  it "computes the closed form over units and locales" do
    total = described_class.estimate_input_tokens(
      game_with(:levels => 5), %w[en pl], :client => CountingClient.new
    )

    expect(total).to eq(1480)
  end

  it "sends a non-empty baseline source, because the API rejects an empty text block" do
    client = CountingClient.new
    described_class.estimate_input_tokens(game_with(:levels => 2), %w[en], :client => client)

    baseline = client.calls.find { |key, _locale, _length| key == "estimate:baseline" }
    expect(baseline.last).to be > 0
  end

  it "costs nothing when every requested locale is the primary one" do
    client = CountingClient.new

    expect(described_class.estimate_input_tokens(game_with(:levels => 3), %w[ru], :client => client))
      .to eq(0)
    expect(client.calls).to be_empty
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/services/translation/estimate_spec.rb`
Expected: FAIL. The first example fails with `expected: 3, got: 6` (the old loop makes units × locales calls), and the arithmetic example fails on the total.

- [ ] **Step 3: Let a Unit carry a supplied source**

In `app/services/translation/unit.rb`, replace `initialize` and `source_text`, and add `raw`:

```ruby
    # A unit whose source text is supplied directly rather than derived from
    # fields. The estimator needs two shapes that correspond to no record set:
    # a baseline carrying almost nothing, and a bulk unit carrying every
    # source at once. Both go through the same request_body as a real call,
    # which is what keeps the estimate describing the run that will happen.
    def self.raw(key, text)
      new(key, [], :source => text)
    end

    def initialize(key, fields, source: nil)
      @key    = key
      @fields = fields
      @source = source
    end

    # Every field is labelled with the key the model must echo back, so the
    # response maps to records without positional guessing.
    def source_text
      return @source unless @source.nil?

      @fields.map do |missing|
        "#{self.class.field_key(missing.record, missing.field)}: #{missing.record[missing.field]}"
      end.join("\n\n")
    end
```

- [ ] **Step 4: Rewrite the estimator**

In `app/services/translation/runner.rb`, replace the whole `self.estimate_input_tokens` method (currently lines 64-79, including its comment block) with:

```ruby
    # One character, not none: the Anthropic API rejects an empty text block and
    # the unit source IS a text block. Costs roughly one token per baseline
    # call, which is noise against a five-figure estimate.
    BASELINE_SOURCE = ".".freeze

    # A pre-flight whose cost does not grow with the game.
    #
    # Every call this run will make is [RULES][unit source][instruction], so a
    # call's input is CONST + tokens(source) + tokens(instruction for locale),
    # and the job total is:
    #
    #   n_units x SUM_locales baseline(locale)  +  n_locales x SUM_units tokens(source)
    #
    # Both terms are measurable in a constant number of calls: one baseline per
    # locale (a unit carrying only BASELINE_SOURCE, so the result is CONST plus
    # that locale's instruction), and one bulk call carrying every source at
    # once, minus that baseline.
    #
    # It was one count_tokens per unit per locale, run synchronously inside the
    # POST that renders the confirmation screen -- 71 round trips for a 70-level
    # quiz at one language and ~426 at six. The 400-field cap was the only
    # reason that was never reached; Task 5 removes that shelter, so this had to
    # go first.
    #
    # Approximate in two known ways, both far below the estimate's existing
    # variance against real spend (prompt caching means billed input is a
    # fraction of this): the baseline carries one character rather than none,
    # and concatenating sources tokenises a few tokens differently at each
    # boundary.
    def self.estimate_input_tokens(game, locales, client: nil)
      effective = locales.reject { |l| l.to_s == game.primary_locale.to_s }
      return 0 if effective.empty?

      units = units_for(game, effective)
      return 0 if units.empty?

      client ||= Client.new(:api_key => ENV["ANTHROPIC_API_KEY"],
                            :model   => Setting.enum("translation_model"))

      baselines = effective.map do |locale|
        client.count_input_tokens(:unit   => Unit.raw("estimate:baseline", BASELINE_SOURCE),
                                  :locale => locale)
      end

      bulk = client.count_input_tokens(
        :unit   => Unit.raw("estimate:bulk", units.map(&:source_text).join("\n\n")),
        :locale => effective.first
      )
      sources = bulk - baselines.first

      units.size * baselines.sum + effective.size * sources
    end
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/services/translation/estimate_spec.rb`
Expected: `5 examples, 0 failures`.

- [ ] **Step 6: Run the neighbouring specs that touch this seam**

Run: `bundle exec rspec spec/services/translation spec/requests/translation_runs_spec.rb`
Expected: `0 failures`. `spec/services/translation/unit_spec.rb` covers the constructor you just changed, and the request spec stubs `estimate_input_tokens` wholesale — both must still pass.

- [ ] **Step 7: Commit**

```bash
git add app/services/translation/unit.rb app/services/translation/runner.rb spec/services/translation/estimate_spec.rb
git commit -m "Price a translation run in a constant number of calls"
```

---

### Task 4: Split the bulk call for very large games

One `count_tokens` over every source concatenated is fine for a 70-level quiz and not fine without bound — a game large enough would exceed the model's input limit and the estimate would fail (rendering "unknown", not blocking the run, but losing the cost guard). Split into a handful of pieces. The call count stays independent of unit count.

**Files:**
- Modify: `app/services/translation/runner.rb` (the `estimate_input_tokens` written in Task 3)
- Modify: `spec/services/translation/estimate_spec.rb`

**Interfaces:**
- Consumes: `Translation::Runner.estimate_input_tokens` from Task 3.
- Produces:
  - `Translation::Runner::BULK_SOURCE_CHARS` → `Integer`
  - `Translation::Runner.bulk_groups(units)` → `Array<Array<Unit>>`
  - `Translation::Runner.source_tokens(units, locale, baseline, client)` → `Integer`

- [ ] **Step 1: Write the failing specs**

Append inside the `describe` block in `spec/services/translation/estimate_spec.rb`:

```ruby
  describe "very large games" do
    # Forced small so the split is reachable without building a game with
    # megabytes of source text.
    before { stub_const("Translation::Runner::BULK_SOURCE_CHARS", 120) }

    it "splits the bulk call rather than sending one unbounded prompt" do
      client = CountingClient.new
      described_class.estimate_input_tokens(game_with(:levels => 10), %w[en], :client => client)

      bulk = client.calls.select { |key, _locale, _length| key == "estimate:bulk" }
      expect(bulk.size).to be > 1
      expect(bulk.map(&:last)).to all(be <= 120 + 60)
    end

    it "still counts every source exactly once across the pieces" do
      client = CountingClient.new
      total  = described_class.estimate_input_tokens(game_with(:levels => 10), %w[en], :client => client)

      # Each bulk piece returns BASELINE + SOURCES and contributes SOURCES after
      # its baseline is subtracted, so the sources term is pieces x SOURCES.
      pieces = client.calls.count { |key, _locale, _length| key == "estimate:bulk" }
      units  = 11 # 1 game header + 10 levels
      expect(total).to eq(units * CountingClient::BASELINE + pieces * CountingClient::SOURCES)
    end

    it "keeps the call count independent of unit count even when splitting" do
      client = CountingClient.new
      described_class.estimate_input_tokens(game_with(:levels => 10), %w[en], :client => client)

      # One baseline plus a small number of pieces -- emphatically not 11.
      expect(client.calls.size).to be < 11
    end
  end

  describe ".bulk_groups" do
    it "never puts a single oversized unit in a group of its own with others" do
      stub_const("Translation::Runner::BULK_SOURCE_CHARS", 10)
      units = [ Translation::Unit.raw("a", "x" * 50),
                Translation::Unit.raw("b", "y" * 50) ]

      groups = described_class.bulk_groups(units)

      expect(groups.size).to eq(2)
      expect(groups.map(&:size)).to eq([ 1, 1 ])
    end

    it "packs units that fit together into one group" do
      stub_const("Translation::Runner::BULK_SOURCE_CHARS", 100)
      units = [ Translation::Unit.raw("a", "x" * 10),
                Translation::Unit.raw("b", "y" * 10) ]

      expect(described_class.bulk_groups(units).size).to eq(1)
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/translation/estimate_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'bulk_groups'`, and the splitting examples fail because the current implementation always makes exactly one bulk call.

- [ ] **Step 3: Implement the split**

In `app/services/translation/runner.rb`, add the constant beside `BASELINE_SOURCE`:

```ruby
    # How much source text goes into one bulk count_tokens call. Well under any
    # model's input limit, and the only thing this bounds is the SIZE of a
    # pre-flight call -- never how many of them there are per unit, which is the
    # property the whole rewrite exists to hold.
    BULK_SOURCE_CHARS = 200_000
```

Replace the `bulk`/`sources` lines inside `estimate_input_tokens` with a call to the new helper:

```ruby
      sources = source_tokens(units, effective.first, baselines.first, client)

      units.size * baselines.sum + effective.size * sources
    end

    # Sum of tokens across every unit's source, measured in as few calls as the
    # size limit allows. Each piece's own baseline is subtracted, because every
    # call carries the rules prefix and the instruction whether it is measuring
    # one unit or a hundred.
    def self.source_tokens(units, locale, baseline, client)
      bulk_groups(units).sum do |group|
        text = group.map(&:source_text).join("\n\n")
        client.count_input_tokens(:unit   => Unit.raw("estimate:bulk", text),
                                  :locale => locale) - baseline
      end
    end

    # Greedy packing. A unit whose own source exceeds the limit still gets a
    # group to itself rather than being dropped or split mid-text: an over-long
    # single prompt is the API's problem to report, and silently omitting a
    # level from the estimate would be worse than an estimate that failed.
    def self.bulk_groups(units)
      groups = []
      size   = 0

      units.each do |unit|
        length = unit.source_text.length
        if groups.empty? || (groups.last.any? && size + length > BULK_SOURCE_CHARS)
          groups << []
          size = 0
        end
        groups.last << unit
        size += length
      end

      groups
    end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/services/translation/estimate_spec.rb`
Expected: `10 examples, 0 failures` — the 5 from Task 3 plus the 5 added here.

- [ ] **Step 5: Commit**

```bash
git add app/services/translation/runner.rb spec/services/translation/estimate_spec.rb
git commit -m "Split the pre-flight bulk call for very large games"
```

---

### Task 5: Raise the cap

**Only after Tasks 3 and 4 are committed.** With the estimator still O(units × locales), this task converts a clean refusal into a hung request.

**Files:**
- Modify: `app/models/setting.rb:41-46`
- Modify: `spec/models/setting_translation_keys_spec.rb:30-36`
- Modify: `spec/requests/translation_runs_spec.rb`

**Interfaces:**
- Consumes: `Setting.integer("translation_max_fields_per_run")`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing specs**

In `spec/models/setting_translation_keys_spec.rb`, change the expected default:

```ruby
  it "caps the fields one run may translate" do
    expect(Setting.integer("translation_max_fields_per_run")).to eq(5_000)

    Setting.put("translation_max_fields_per_run", 50)
    expect(Setting.integer("translation_max_fields_per_run")).to eq(50)
  end
```

In `spec/requests/translation_runs_spec.rb`, add beside the existing cap example (the one that puts the setting to `1`, which stays exactly as it is):

```ruby
  # The reported bug: a ~70-level quiz is ~492 fields at one language and was
  # refused outright. The work-list is stubbed rather than built, because
  # creating 500 records to exercise one integer comparison is a slow way to
  # assert nothing extra. Runner.estimate_input_tokens is already stubbed for
  # this whole file, so no network is involved.
  it "no longer refuses a game that is merely large" do
    allow(Translation::Runner).to receive(:plan).and_return(Array.new(492, :field))

    expect { post game_translation_runs_path(game), :params => { :locales => %w[en] } }
      .not_to change { TranslationRun.count }

    expect(flash[:alert]).to be_nil
    expect(response.body).to include(I18n.t("translations.confirm.submit"))
  end
```

Note it must NOT create a run: an unconfirmed POST renders the confirmation screen, and that is the behaviour being asserted.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/models/setting_translation_keys_spec.rb spec/requests/translation_runs_spec.rb`
Expected: FAIL — the setting example with `expected: 5000, got: 400`, and the new request example because `flash[:alert]` holds the `too_large` message.

- [ ] **Step 3: Raise the default**

In `app/models/setting.rb`, replace the `TRANSLATION_DEFAULTS` block and its comment:

```ruby
  # Blast radius for one AI translation run, counted in FIELDS x LOCALES --
  # Runner.plan flattens the work-list across locales, so translating into six
  # languages costs six times the fields.
  #
  # Raised from 400 on 2026-08-17. 400 was not a cost ceiling in practice, it
  # was a wall: a ~70-level quiz is ~492 fields at ONE language and could not be
  # translated at all. 5000 clears that game into all six non-primary locales
  # (~2952) with headroom, while still refusing something pathological. This is
  # a backstop, not a working limit -- the cost guard is the confirmation
  # screen, which prices the run before anything is spent.
  TRANSLATION_DEFAULTS = {
    "translation_max_fields_per_run" => 5_000
  }.freeze
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/models/setting_translation_keys_spec.rb spec/requests/translation_runs_spec.rb`
Expected: `0 failures`.

- [ ] **Step 5: Commit**

```bash
git add app/models/setting.rb spec/models/setting_translation_keys_spec.rb spec/requests/translation_runs_spec.rb
git commit -m "Stop refusing games that are merely large"
```

---

### Task 6: Full verification

Both PRs' worth of change, verified together against the gates this repository actually trusts. **Do not report completion without the output of each of these.**

- [ ] **Step 1: Full RSpec**

Run: `bin/rails db:test:prepare && bundle exec rspec`
Expected: `0 failures`. The pending count (6, unimplemented controller specs) is pre-existing.
Do not quote a remembered example count — `CLAUDE.md`'s figure has been stale repeatedly. Report what this run prints.

- [ ] **Step 2: Layout suite**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout`
Expected: `26 examples, 0 failures`.

- [ ] **Step 3: The inherited Cucumber contract**

The frozen 58 pre-port files. This is the figure that must never move.

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: `228 scenarios (2 undefined, 226 passed)`, `2325 steps`.

- [ ] **Step 4: Full Cucumber**

Run: `bundle exec cucumber`
Expected: `238 scenarios (2 undefined, 236 passed)`, `2386 steps`.

- [ ] **Step 5: Confirm no feature file was touched**

Run: `git diff --stat origin/master -- 'features/**/*.feature'`
Expected: no output at all. Any output is a contract breach and must be reverted.

---

## Manual verification worth doing before merge

Neither suite can price a real API call, and the estimator's accuracy is the one property a stub cannot check. On a real game with a real key, start a run and compare the confirmation screen's estimate against the run page's actual `input_tokens` when it finishes. They will not match exactly — prompt caching means billed input is a fraction of the estimate — but the estimate should be the right order of magnitude and should scale sensibly with locale count. If it is out by more than a factor of two, the `BASELINE_SOURCE` subtraction is the first thing to check.
