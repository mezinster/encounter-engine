# Operator on a Phone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the operator's live-game screens (standings and interventions, live channel, full log, results, and four overflow-only screens) usable on a 390px phone, with a self-refreshing data region, without changing desktop or any frozen scenario.

**Architecture:** CSS-first on the existing templates. One shared vanilla script (`public/javascripts/live_region.js`) plus one partial (`shared/_live_status`) refreshes any `[data-live]` region. Each screen gets small markup additions (classes, a sticky `.opbar`, panel log buttons, «— нет ответов», a ✓) and phone-only CSS under `@media (max-width: 47.99rem)`. Two new layout specs measure the result in a real browser.

**Tech Stack:** Rails 8 ERB, vanilla CSS with tokens, vanilla JS (no framework, no Turbo), RSpec (request and plain specs), Node for the script spec, `spec/support/layout_measurement.rb` with chrome-headless-shell.

**Spec:** `docs/superpowers/specs/2026-10-01-operator-mobile-design.md`. Read it alongside this plan; the spec wins where they differ.

## Global Constraints

- Work only in the worktree `.claude/worktrees/operator-mobile`, branch `design/operator-mobile`.
- Prefix every command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" &&`.
- Every RSpec run uses an isolated DB:
  - `export RAILS_ENV=test DATABASE_URL="sqlite3:/tmp/claude-1000/-home-mezinster-encounter-engine/aebf2b26-bc2a-403f-b757-11277eb435e8/scratchpad/om_taskN.sqlite3"`, where N is your task number;
  - run `bin/rails db:schema:load` once first.
- **Never edit any `features/**/*.feature` file.** Frozen facts these screens must keep:
  - the standings page has the links «(лог по уровню)» and «(лог по игре)», clickable by rack-test (`features/logs/log.feature:29-61`);
  - «Полный лог ответов» stays a link on the standings page and the full log's title begins with that phrase;
  - every existing string on the live channel and full log stays in the markup.
- Hiding rule: a frozen link may be hidden from people **only** by a rule in an external stylesheet. Never use an inline `style`, a `hidden` attribute, or a closed `<details>`, because rack-test treats each of those as invisible (CLAUDE.md, "the CSS-hidden locale dropdown").
- Desktop (≥48rem) must stay visually unchanged, except the two full-log markup additions and the panel's two new buttons.
- Every user-facing string goes through `t()`. The new keys go in **all seven** `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`, inside the existing mapping named in the task. Never create a second copy of a mapping. Author-written content (team, level, game names, answers) is rendered verbatim.
- YAML check after any locale edit: `ruby -ryaml -e 'Dir["config/locales/*.yml"].each { |f| YAML.unsafe_load_file(f) }; puts "ok"'`.
- CSS rules:
  - tokens only, enforced by `spec/stylesheets/token_discipline_spec.rb`: font sizes `var(--text-*)`, z-index `var(--z-*)`;
  - `@media` widths only 48rem / 47.99rem / 52rem / 60rem;
  - no shadows or gradients.
- Code style: hash rockets in Ruby; English comments; literal Russian in spec assertions, never `include(I18n.t(...))`.
- Link any new stylesheet or script through `versioned_asset("/javascripts/…")` (ApplicationHelper), never a literal URL. `spec/assets_versioned_spec.rb` fails otherwise.
- Never change a controller's response format or add a route. The one controller change allowed is Task 4's preload.
- Run only the specs your task names. No full RSpec or Cucumber suite and no background processes. Layout specs run in the foreground with `LAYOUT_SPECS=1`.
- Precise edits only. Check `git diff --stat` before committing. Write reports with your file tool, never a shell heredoc. Commit messages are plain, with no attribution lines.

## Review Focus

1. **An operator mid-action when a refresh tick lands.** A team panel is open, or the move `<select>` has focus. The refresh must skip that tick and must not swap even if the fetch was already in flight. Pinned in Task 1.
2. **The session expires, or the operator logs out in another tab.** The poll then gets the login page: HTTP 200 with no live region. The old content must stay and nothing breaks. Pinned in Task 1.
3. **A paused game on a phone.** «Игра приостановлена в …» and «Продолжить игру» sit in the sticky bar and can be tapped at both ends of a long scroll. Pinned in Task 6.
4. **Very long unbroken team names, level names and answers.** No page-level or inner sideways scroll on any in-scope screen at 390px, and the panel button stays on screen. Pinned in Tasks 6 and 7.
5. **The ✓ must agree with how the game scores.** It appears on a case or whitespace variant of the code. It does not appear on a wrong answer, or on a quiz level's leftover code that the game refuses. Pinned in Task 4.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `public/javascripts/live_region.js` (new) | poll, hold, swap, stamp, pause toggle | 1 |
| `app/views/shared/_live_status.html.erb` (new) | stamp, toggle and `<script>` tag for a live screen | 1 |
| `spec/live_region_script_spec.rb` (new) | the script's pure functions under Node | 1 |
| `spec/views/shared/live_status_spec.rb` (new) | the partial's markup | 1 |
| `config/locales/*.yml` (7) | `shared.live_status.*` (T1); `game_passings.index.*_log_button` (T3); `logs.show_full_log.no_answers/accepted` (T4) | 1, 3, 4 |
| `app/views/game_passings/index.html.erb`, `_intervention_controls.html.erb` | standings markup, `.ops`/`.opbar`, panel log buttons | 3 |
| `public/stylesheets/screens.css` | `.ops`/`.opbar`, `.standings`, `.table--compact`, live channel, `.log-matrix` | 3, 4 |
| `public/stylesheets/components.css` / `layout.css` | `.table--compact` base, `.main` wrap, `code` wrap | 2 |
| `spec/requests/operator_standings_spec.rb` (new) | standings markup | 3 |
| `app/views/logs/show_full_log.html.erb`, `show_live_channel.html.erb`, `app/controllers/logs_controller.rb` | full log restack, ✓, «нет ответов», live regions; `:options` preload | 4 |
| `spec/requests/operator_logs_spec.rb` (new) | full log and live channel markup | 4 |
| `app/views/game_passings/show_results.html.erb` | results live region | 5 |
| `spec/requests/operator_results_spec.rb` (new) | results live region | 5 |
| `spec/layout/operator_standings_layout_spec.rb` (new) | measured standings | 6 |
| `spec/layout/operator_logs_layout_spec.rb` (new) | measured logs and overflow-only screens | 7 |
| `CLAUDE.md` | docs | 8 |

---

### Task 1: The refresh script and its status partial

**Files:**
- Create: `public/javascripts/live_region.js`, `app/views/shared/_live_status.html.erb`, `spec/live_region_script_spec.rb`, `spec/views/shared/live_status_spec.rb`
- Modify: `config/locales/*.yml` (7 files)

**Interfaces — Produces:**
- `render "shared/live_status"` emits the stamp, the toggle and the script tag. A page using it must also have exactly one element with `data-live` and a unique `id`.
- The script exposes `LiveRegion` with:
  - `holdReason(doc, region)` → `"hidden" | "panel" | "focus" | null`;
  - `formatStamp(template, seconds)` → String;
  - `readPaused(storage)` → Boolean;
  - `writePaused(storage, paused)`;
  - `extractRegion(parse, html, id)` → Element or null;
  - `start(doc, win)`.

  It assigns `window.LiveRegion` in a browser and `module.exports` under Node.
- Keys:
  - `shared.live_status.updated` = «Обновлено %{seconds} с назад»;
  - `shared.live_status.pause` = «Пауза обновления»;
  - `shared.live_status.resume` = «Возобновить обновление».

- [ ] **Step 1: Write the failing script spec** — `spec/live_region_script_spec.rb`:

```ruby
require "rails_helper"
require "open3"
require "json"

# public/javascripts/live_region.js, run under Node -- the same reasoning as
# spec/views/countdown_spec.rb: assert what the shipped JavaScript actually
# does, not a Ruby mirror of it. A missing node RAISES rather than skips (CI
# installs it; a skip would read like a pass).
describe "live_region.js" do
  SCRIPT = Rails.root.join("public/javascripts/live_region.js").to_s

  before do
    _, status = Open3.capture2("node", "--version") rescue raise("node is not on PATH; these examples must run, not skip")
  end

  def run_js(body)
    harness = "var LR = require(#{SCRIPT.to_json});\n#{body}"
    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise "node harness failed: #{stderr}" unless status.success?
    JSON.parse(stdout.strip)
  end

  # Fakes: only the members the functions read.
  FAKES = <<~JS
    function region(open) { return { querySelector: function (s) { return s === "details[open]" && open ? {} : null; } }; }
    function doc(hidden, tag) { return { hidden: hidden, activeElement: tag ? { tagName: tag } : null }; }
  JS

  it "holds while the tab is hidden, a panel is open, or a field has focus" do
    result = run_js(FAKES + <<~JS)
      console.log(JSON.stringify([
        LR.holdReason(doc(true, null), region(false)),
        LR.holdReason(doc(false, null), region(true)),
        LR.holdReason(doc(false, "SELECT"), region(false)),
        LR.holdReason(doc(false, "INPUT"), region(false)),
        LR.holdReason(doc(false, "TEXTAREA"), region(false)),
        LR.holdReason(doc(false, "BUTTON"), region(false)),
        LR.holdReason(doc(false, null), region(false))
      ]));
    JS
    expect(result).to eq(["hidden", "panel", "focus", "focus", "focus", nil, nil])
  end

  it "formats the stamp from the translated template" do
    result = run_js('console.log(JSON.stringify(LR.formatStamp("Обновлено %{seconds} с назад", 12)));')
    expect(result).to eq("Обновлено 12 с назад")
  end

  it "remembers the paused state, and survives a storage that throws" do
    result = run_js(<<~JS)
      var mem = {}; var good = { getItem: function (k) { return mem[k] || null; },
                                 setItem: function (k, v) { mem[k] = v; }, removeItem: function (k) { delete mem[k]; } };
      var bad = { getItem: function () { throw new Error("denied"); }, setItem: function () { throw new Error("denied"); },
                  removeItem: function () { throw new Error("denied"); } };
      var before = LR.readPaused(good); LR.writePaused(good, true); var after = LR.readPaused(good);
      LR.writePaused(good, false); var cleared = LR.readPaused(good);
      LR.writePaused(bad, true);
      console.log(JSON.stringify([before, after, cleared, LR.readPaused(bad), LR.readPaused(null)]));
    JS
    expect(result).to eq([false, true, false, false, false])
  end

  # A fetched page without the region -- the login page after the session
  # expired, an error page -- must swap nothing.
  it "finds the region in a fetched page, and returns null when it is absent" do
    result = run_js(<<~JS)
      function parse(html) { return { getElementById: function (id) { return html.indexOf('id="' + id + '"') >= 0 ? { innerHTML: "fresh" } : null; } }; }
      var found = LR.extractRegion(parse, '<div id="standings-live">x</div>', "standings-live");
      var missing = LR.extractRegion(parse, '<form id="login">', "standings-live");
      var unparsable = LR.extractRegion(function () { return null; }, "", "standings-live");
      console.log(JSON.stringify([found && found.innerHTML, missing, unparsable]));
    JS
    expect(result).to eq(["fresh", nil, nil])
  end
end
```

- [ ] **Step 2: Run it.** Expect failure: `Cannot find module` raised from the harness.

  Run: `bundle exec rspec spec/live_region_script_spec.rb`

- [ ] **Step 3: Write the script** — `public/javascripts/live_region.js`:

```js
/* public/javascripts/live_region.js
 *
 * Refreshes one [data-live] region on an operator's live-game screen (standings,
 * live channel, full log, results) without reloading the page: every 20 s it
 * fetches the same URL (query string included, so the pager's page is kept),
 * takes the element with the region's id out of the response and swaps its
 * contents, keeping the scroll position.
 *
 * It HOLDS -- skips the tick, does not queue it -- while the tab is hidden,
 * while any <details> in the region is open (an intervention panel), or while
 * a form field has focus anywhere on the page; and re-checks after the fetch,
 * so a panel opened while a request was in flight is not swapped away. A
 * response without the region (an error page, the login page after the
 * session expired) swaps nothing: the old content stays and the stamp keeps
 * counting, so staleness is visible.
 *
 * Without JavaScript the page is the static page it always was; the status
 * line (shared/_live_status) stays hidden because it would be a lie.
 */
(function (root) {
  "use strict";

  var INTERVAL_MS = 20000;
  var STORAGE_KEY = "liveRegionPaused";

  function holdReason(doc, region) {
    if (doc.hidden) return "hidden";
    if (region.querySelector("details[open]")) return "panel";
    var active = doc.activeElement;
    if (active && /^(INPUT|SELECT|TEXTAREA)$/.test(active.tagName)) return "focus";
    return null;
  }

  function formatStamp(template, seconds) {
    return String(template).replace("%{seconds}", String(seconds));
  }

  // localStorage throws in some private windows and when site data is
  // blocked; a remembered pause is a convenience, never a requirement.
  function readPaused(storage) {
    try { return !!storage && storage.getItem(STORAGE_KEY) === "1"; } catch (e) { return false; }
  }

  function writePaused(storage, paused) {
    try {
      if (!storage) return;
      if (paused) storage.setItem(STORAGE_KEY, "1"); else storage.removeItem(STORAGE_KEY);
    } catch (e) { /* see readPaused */ }
  }

  function extractRegion(parse, html, id) {
    var parsed = parse(html);
    return parsed ? parsed.getElementById(id) : null;
  }

  function storageOf(win) {
    try { return win.localStorage; } catch (e) { return null; }
  }

  function start(doc, win) {
    var region = doc.querySelector("[data-live]");
    var status = doc.querySelector("[data-live-status]");
    if (!region || !region.id || !status || !win.fetch || !win.DOMParser) return;

    var stamp = status.querySelector("[data-live-stamp]");
    var toggle = status.querySelector("[data-live-toggle]");
    var storage = storageOf(win);
    var paused = readPaused(storage);
    var lastSwap = Date.now();

    function render() {
      stamp.textContent = formatStamp(status.getAttribute("data-template"),
                                      Math.round((Date.now() - lastSwap) / 1000));
      toggle.textContent = status.getAttribute(paused ? "data-resume-label" : "data-pause-label");
      toggle.setAttribute("aria-pressed", paused ? "true" : "false");
    }

    function parse(html) { return new win.DOMParser().parseFromString(html, "text/html"); }

    function tick() {
      if (paused || holdReason(doc, region)) return;
      win.fetch(win.location.href, { headers: { "X-Requested-With": "XMLHttpRequest" },
                                     credentials: "same-origin" })
        .then(function (response) { return response.ok ? response.text() : null; })
        .then(function (html) {
          if (!html || paused || holdReason(doc, region)) return;
          var fresh = extractRegion(parse, html, region.id);
          if (!fresh) return;
          var x = win.scrollX, y = win.scrollY;
          region.innerHTML = fresh.innerHTML;
          win.scrollTo(x, y);
          lastSwap = Date.now();
          render();
        })
        .catch(function () { /* keep the old content; the stamp shows its age */ });
    }

    toggle.addEventListener("click", function () {
      paused = !paused;
      writePaused(storage, paused);
      render();
    });

    status.hidden = false;
    render();
    win.setInterval(render, 1000);
    win.setInterval(tick, INTERVAL_MS);
  }

  var api = { holdReason: holdReason, formatStamp: formatStamp, readPaused: readPaused,
              writePaused: writePaused, extractRegion: extractRegion, start: start };

  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.LiveRegion = api;
  if (typeof document !== "undefined" && typeof window !== "undefined") start(document, window);
})(typeof window !== "undefined" ? window : this);
```

- [ ] **Step 4: Run the script spec.** Expect 4 examples, 0 failures.

- [ ] **Step 5: Add the keys.** In each locale file, the top-level `shared:` mapping (in `ru.yml` it is around line 862 and holds `times_in_zone`, `test_runs`, …) gains a `live_status:` block. Values:

| key | ru | en | uk | be | pl | tr | ka |
|---|---|---|---|---|---|---|---|
| updated | Обновлено %{seconds} с назад | Updated %{seconds} s ago | Оновлено %{seconds} с тому | Абноўлена %{seconds} с таму | Zaktualizowano %{seconds} s temu | %{seconds} sn önce güncellendi | განახლდა %{seconds} წმ-ის წინ |
| pause | Пауза обновления | Pause updates | Призупинити оновлення | Прыпыніць абнаўленне | Wstrzymaj odświeżanie | Güncellemeyi duraklat | განახლების შეჩერება |
| resume | Возобновить обновление | Resume updates | Відновити оновлення | Аднавіць абнаўленне | Wznów odświeżanie | Güncellemeyi sürdür | განახლების გაგრძელება |

- [ ] **Step 6: Write the partial spec, then the partial.**

`spec/views/shared/live_status_spec.rb`:

```ruby
require "rails_helper"

describe "shared/_live_status", type: :view do
  it "renders a hidden status line carrying the untranslated %{seconds} slot and both labels" do
    render :partial => "shared/live_status"
    node = Nokogiri::HTML(rendered).at_css("[data-live-status]")

    expect(node["hidden"]).not_to be_nil
    expect(node["data-template"]).to eq("Обновлено %{seconds} с назад")
    expect(node["data-pause-label"]).to eq("Пауза обновления")
    expect(node["data-resume-label"]).to eq("Возобновить обновление")
    expect(node.at_css("button[type=button][data-live-toggle]")).to be_present
    expect(rendered).to match(%r{src="/javascripts/live_region\.js\?v=[0-9a-f]{12}"})
  end
end
```

`app/views/shared/_live_status.html.erb`:

```erb
<%# The refresh stamp and pause toggle for a screen with one [data-live]
    region (public/javascripts/live_region.js). Rendered hidden: the script
    unhides it, so without JavaScript nothing claims the page is updating.
    data-template keeps the literal %{seconds} -- t() without an interpolation
    hash returns the string untouched -- and the script fills it in. %>
<p class="live-status" data-live-status hidden
   data-template="<%= t("shared.live_status.updated") %>"
   data-pause-label="<%= t("shared.live_status.pause") %>"
   data-resume-label="<%= t("shared.live_status.resume") %>">
  <span data-live-stamp></span>
  <button type="button" class="btn btn--quiet" data-live-toggle aria-pressed="false"></button>
</p>
<script src="<%= versioned_asset("/javascripts/live_region.js") %>" defer></script>
```

- [ ] **Step 7: Run** `bundle exec rspec spec/live_region_script_spec.rb spec/views/shared/live_status_spec.rb spec/i18n_spec.rb`, after the YAML check. Expect 0 failures.

- [ ] **Step 8: Commit**

```bash
git add public/javascripts/live_region.js app/views/shared/_live_status.html.erb spec/live_region_script_spec.rb spec/views/shared/live_status_spec.rb config/locales
git commit -m "Add a live-region refresh script and its status line

Polls the page's [data-live] region every 20 s and swaps it in place,
holding while a panel is open, a field has focus or the tab is hidden,
and keeping the old content when the response lacks the region."
```

---

### Task 2: Shared phone CSS (`.table--compact`, wrap rules)

**Files:**
- Modify: `public/stylesheets/components.css` (Tables block), `public/stylesheets/layout.css` (`.main`)

**Interfaces — Produces:**
- `.table--compact`, used together with `.table--cards`: below 47.99rem the `td::before` labels are suppressed, and cells get tighter padding and `overflow-wrap: anywhere`.
- `.main` gets `overflow-wrap: break-word`.
- `code` gets `overflow-wrap: anywhere`.

- [ ] **Step 1: Add to `components.css`**, directly after the existing `@media (max-width: 47.99rem) { .table--cards … }` block:

```css
/* .table--compact: a .table--cards table whose rows are short enough to read
 * as lines rather than labelled cards -- the operator's standings and live
 * channel, read at a glance mid-game. The per-cell labels go; each screen
 * arranges its own cells (screens.css: .standings, #livechannel). Long
 * unbroken names and answers wrap inside the card instead of widening it. */
@media (max-width: 47.99rem) {
  .table--compact td::before { content: none; }
  .table--compact td { padding: 0 var(--space-1); overflow-wrap: anywhere; }
}
```

- [ ] **Step 2: Add wrapping.**
  - In `layout.css`, inside the existing `.main { … }` rule (around line 85), add `overflow-wrap: break-word;`. Give it a comment: `break-word`, not `anywhere`, so a table's min-content width and therefore desktop column layout are unchanged; it only stops a long unbroken name or answer in block text from pushing the page sideways at 390px (measured 93–146px on four operator screens).
  - In `components.css`, add `code { overflow-wrap: anywhere; }` with a one-line comment: the test-run invite link on the game page is one unbroken URL.

- [ ] **Step 3: Run** `bundle exec rspec spec/stylesheets/token_discipline_spec.rb spec/requests/home_page_spec.rb spec/views/index_spec.rb`. Expect 0 failures. These are smoke checks that the site still renders; layout is measured in Tasks 6 and 7.

- [ ] **Step 4: Commit:** `git commit -m "Add a compact card-table modifier and long-word wrapping"`.

---

### Task 3: Standings and interventions on a phone

**Files:**
- Modify: `app/views/game_passings/index.html.erb`, `app/views/game_passings/_intervention_controls.html.erb`, `public/stylesheets/screens.css`, `config/locales/*.yml`
- Create: `spec/requests/operator_standings_spec.rb`

**Interfaces — Consumes:** `shared/_live_status` (Task 1); `.table--compact` (Task 2).
**Produces:**
- Markup: `div.ops` > `div#standings-live.table-wrap[data-live]` > `table#stats.table--cards.table--compact.standings`. Each row has cells `td.standings-team`, `td.standings-level`, `td.standings-time`, `td.standings-log` (×2) and `td.standings-actions`.
- Then `p.ops-full-log`, then `div.opbar` containing `p.game-control` (pause/resume) and the live status.
- Keys:
  - `game_passings.index.level_log_button` = «Лог уровня»;
  - `game_passings.index.game_log_button` = «Лог игры».

- [ ] **Step 1: Write the failing request spec** — `spec/requests/operator_standings_spec.rb`:

```ruby
require "rails_helper"

# The operator's standings screen (/stats/index/:game_id), reworked for a
# phone. Literal Russian, not I18n.t(...), which passes with a key missing.
describe "the operator's standings screen", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let!(:level) { create_level(:game => game) }
  let!(:playing)  { create_game_passing(:level => level) }
  let!(:finished) { p = create_game_passing(:level => level); p.update_column(:finished_at, Time.now); p }
  let(:doc) { Nokogiri::HTML(response.body) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def row_for(passing)
    doc.css("#stats tbody tr").find { |tr| tr.at_css(".standings-team").text.include?(passing.team.name) }
  end

  before { sign_in(author); get game_stats_path(game) }

  # features/logs/log.feature:29-61 clicks these on this page. They stay in
  # the row's markup; phones hide them with an external stylesheet rule only.
  it "keeps the frozen log links in the row, outside the panel" do
    row = row_for(playing)
    links = row.css("td.standings-log a").map { |a| a.text.strip }
    expect(links).to eq(["(лог по уровню)", "(лог по игре)"])
    expect(row.css("details a").map { |a| a.text.strip }).not_to include("(лог по уровню)", "(лог по игре)")
    expect(row.css("td.standings-log").map { |td| td["style"] }.compact).to be_empty
  end

  it "opens with full-size log buttons in the intervention panel" do
    panel = row_for(playing).at_css("details .team-panel-actions")
    buttons = panel.css("a.btn").map { |a| [a.text.strip, a["href"]] }
    expect(buttons).to include(["Лог уровня", show_level_log_path(:game_id => game.id, :team_id => playing.team_id)])
    expect(buttons).to include(["Лог игры", show_game_log_path(:game_id => game.id, :team_id => playing.team_id)])
  end

  it "offers no level-log button for a team that has finished, as the row offers no link" do
    labels = row_for(finished).css("details .team-panel-actions a.btn").map { |a| a.text.strip }
    expect(labels).to include("Лог игры")
    expect(labels).not_to include("Лог уровня")
  end

  it "puts pause and the live status in the control bar after the table" do
    ops = doc.at_css(".ops")
    children = ops.element_children.map { |e| e["class"].to_s.split.first || e.name }
    expect(children).to eq(["table-wrap", "ops-full-log", "opbar"])
    bar = ops.at_css(".opbar")
    expect(bar.at_css("button").text.strip).to eq("Приостановить игру")
    expect(bar.at_css("[data-live-status]")).to be_present
  end

  it "marks only the table as the live region" do
    live = doc.css("[data-live]")
    expect(live.size).to eq(1)
    expect(live.first["id"]).to eq("standings-live")
    expect(live.first.at_css("table#stats.table--cards.table--compact.standings")).to be_present
    expect(live.first.at_css(".opbar")).to be_nil
  end

  it "shows the paused state and the resume button in the bar" do
    game.update_column(:paused_at, 5.minutes.ago)
    get game_stats_path(game)
    bar = doc.at_css(".opbar")
    expect(bar.text).to include("Игра приостановлена в")
    expect(bar.at_css("button").text.strip).to eq("Продолжить игру")
  end
end
```

  The two literals were verified against `config/locales/ru.yml` on 2026-10-01: `game_passings.index.paused_since` is «Игра приостановлена в %{time}.» and `game_passings.index.resume` is «Продолжить игру».

- [ ] **Step 2: Run it.** Expect failures, because none of the new markup exists.

  Run: `bundle exec rspec spec/requests/operator_standings_spec.rb`

- [ ] **Step 3: Rewrite `app/views/game_passings/index.html.erb`.**
  - Keep the title line and the superadmin level-codes fieldset exactly as they are.
  - Remove the top `<p class="game-control">…</p>`; its contents move into `.opbar`, unchanged.
  - Replace everything from `<div class="table-wrap">` to the end of the file with:

```erb
<%# Phone layout (screens.css, .standings / .ops / .opbar): each team is a
    two-line row, its actions and log buttons inside the existing panel, and
    pause/resume in a bar that sticks to the bottom of the screen. The bar
    comes AFTER the table in the markup so position: sticky; bottom: 0 can
    hold it there; .ops puts it back on top from 48rem. Only the table is the
    live region -- the bar is never swapped, so a tap on Pause never lands on
    a node being replaced. %>
<div class="ops">
<div class="table-wrap" id="standings-live" data-live>
<table id="stats" class="table--cards table--compact standings">
  <thead>
    <tr>
      <th><%= t("game_passings.index.team") %></th>
      <th><%= t("game_passings.index.level") %></th>
      <th><%= t("game_passings.index.time_at_level") %></th>
      <th>#</th>
      <th>#</th>
      <th><%= t("game_passings.index.interventions") %></th>
    </tr>
  </thead>
  <tbody>
    <%
      game_passings_sorted_by_current_level_position = @game_passings.sort do |left, right|
        if left.finished?
          -1
        elsif right.finished?
          1
        else
          right.current_level.position <=> left.current_level.position
        end
      end
    %>
    <% game_passings_sorted_by_current_level_position.each do |game_passing| %>
      <tr>
        <td class="standings-team" data-label="<%= t("game_passings.index.team") %>"><%= game_passing.team.name %></td>
        <% if game_passing.exited? %>
          <td class="standings-level" data-label="<%= t("game_passings.index.level") %>"><%= t("game_passings.index.exited") %></td>
          <td class="standings-time" data-label="<%= t("game_passings.index.time_at_level") %>"><%= Level.find(game_passing.current_level_id).name %></td>
        <% elsif game_passing.finished? %>
          <td class="standings-level" data-label="<%= t("game_passings.index.level") %>"><%= t("game_passings.index.finished") %></td>
          <td class="standings-time" data-label="<%= t("game_passings.index.time_at_level") %>">--:--:--</td>
        <% else %>
          <td class="standings-level" data-label="<%= t("game_passings.index.level") %>"><%= game_passing.current_level.name %></td>
          <td class="standings-time" data-label="<%= t("game_passings.index.time_at_level") %>"><%= game_passing.time_at_level %></td>
        <% end %>

        <%# Frozen: features/logs/log.feature:29-61 sees and clicks these two
            links on this page. Phones hide these cells by an external
            stylesheet rule ONLY -- rack-test parses no stylesheet, so they
            stay clickable for the contract. An inline style, a hidden
            attribute or moving them into the closed <details> would each
            make them invisible to it. People on phones use the panel's
            buttons instead (different labels, so click_link never sees two
            matches). %>
        <td class="standings-log" data-label="#">
          <em>
            <%=
               unless game_passing.finished?
                 link_to t("game_passings.index.level_log"), show_level_log_path(game_id: game_passing.game_id, team_id: game_passing.team_id)
               else
                 t("game_passings.index.level_log")
               end
            %>
          </em>
        </td>

        <td class="standings-log" data-label="#">
          <em>
            <%= link_to t("game_passings.index.game_log"), show_game_log_path(game_id: game_passing.game_id, team_id: game_passing.team_id) %>
          </em>
        </td>

        <td class="standings-actions" data-label="<%= t("game_passings.index.interventions") %>">
          <details>
            <summary class="btn team-disclosure"><%= t("game_passings.index.interventions") %></summary>
            <%= render "intervention_controls", :game_passing => game_passing, :levels => @levels %>
          </details>
        </td>

      </tr>
    <% end %>
  </tbody>
</table>
</div>

<p class="ops-full-log"><%= link_to t("game_passings.index.full_log"), show_full_log_path(@game), class: "btn" %></p>

<div class="opbar">
  <p class="game-control">
    <% if @game.paused? %>
      <%= t("game_passings.index.paused_since", :time => l(@game.paused_at, :format => :long)) %>
      <%= button_to t("game_passings.index.resume"), resume_game_path(@game), :method => :post, :class => "btn" %>
    <% else %>
      <%= button_to t("game_passings.index.pause"), pause_game_path(@game), :method => :post, :class => "btn" %>
    <% end %>
  </p>
  <%= render "shared/live_status" %>
</div>
</div>
```

- [ ] **Step 4: Add the panel log buttons.** In `_intervention_controls.html.erb`, make these the first children of `div.team-panel-actions`, before the move form:

```erb
    <%# The row's own log links are hidden on phones (index.html.erb explains
        why they must stay in the row); these are the phone's way to them,
        full-size. Same condition as the row: a finished team has no current
        level to show a log for. %>
    <% unless game_passing.finished? %>
      <%= link_to t("game_passings.index.level_log_button"),
                  show_level_log_path(:game_id => game_passing.game_id, :team_id => game_passing.team_id),
                  :class => "btn" %>
    <% end %>
    <%= link_to t("game_passings.index.game_log_button"),
                show_game_log_path(:game_id => game_passing.game_id, :team_id => game_passing.team_id),
                :class => "btn" %>
```

- [ ] **Step 5: Add the keys** under the existing `game_passings:` → `index:` mapping (in `ru.yml` the one holding `level_log: "(лог по уровню)"`). Match the word each locale file already uses for "log" in its own `level_log`/`game_log` values; the table is the default.

| key | ru | en | uk | be | pl | tr | ka |
|---|---|---|---|---|---|---|---|
| level_log_button | Лог уровня | Level log | Лог рівня | Лог узроўню | Log poziomu | Seviye günlüğü | დონის ჟურნალი |
| game_log_button | Лог игры | Game log | Лог гри | Лог гульні | Log gry | Oyun günlüğü | თამაშის ჟურნალი |

- [ ] **Step 6: CSS.** Append to `public/stylesheets/screens.css`:

```css
/* --- Operator standings on a phone (game_passings/index) -------------------
 * .ops wraps the table, the full-log link and the control bar. The bar is
 * last in the markup (so it can stick to the bottom on a phone) and is moved
 * back to the top from 48rem with flex order, so desktop does not change.
 * gap, not `> * + *` margins: with order changed, a sibling margin would
 * land on the wrong element. */
.ops { display: flex; flex-direction: column; gap: var(--space-4); }
.live-status { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2);
               font-size: var(--text-sm); color: var(--text-dim); }

@media (min-width: 48rem) {
  .ops > .opbar { order: -1; }
  .opbar { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-4); }
}

@media (max-width: 47.99rem) {
  /* The play screen's .playbar treatment (see its comment above): sticky to
     the bottom, full bleed, clear of the iOS home indicator. .ops is the last
     thing in .main, so its negative bottom margin cancels .main's padding and
     the bar can rest on the viewport's bottom edge at maximum scroll. */
  .ops { margin-bottom: calc(-1 * var(--space-5)); }
  .opbar {
    position: sticky;
    bottom: 0;
    z-index: var(--z-sticky);
    margin-left: calc(-1 * var(--space-4));
    margin-right: calc(-1 * var(--space-4));
    padding: var(--space-2) var(--space-4);
    padding-bottom: calc(var(--space-2) + env(safe-area-inset-bottom, 0px));
    background: var(--surface);
    border-top: 1px solid var(--border);
  }
  .opbar .game-control { margin: 0; }

  /* One team = two lines: name, then level · time. The panel button sits
     top-right; an open panel runs full width under the two lines. */
  .standings tr { position: relative; min-height: calc(var(--tap) + 2 * var(--space-2));
                  margin-bottom: var(--space-2); padding: var(--space-2) var(--space-3); }
  .standings .standings-team { font-weight: 600; margin-right: 48%; }
  .standings .standings-level, .standings .standings-time { display: inline; }
  .standings .standings-time::before { content: " · "; color: var(--text-dim); }
  .standings .standings-level { margin-right: 0; }
  .standings .standings-log { display: none; }
  .standings .standings-actions { padding: 0; }
  .standings .team-disclosure { position: absolute; top: var(--space-2); right: var(--space-2);
                                max-width: 46%; }
  .standings details[open] .team-panel { margin-top: var(--space-2); }
  .standings .team-panel-actions .btn,
  .standings .team-panel-actions select,
  .standings .team-panel-actions input[type=submit],
  .standings .team-panel-actions button { min-height: var(--tap); width: 100%; }
}
```

  Read the existing `.team-panel`, `.team-panel-actions` and `.team-disclosure` rules (screens.css ~540–572) first. If one of them already sets something above, do not duplicate it; if an existing rule fights this one (e.g. a width), note it in the report. Do not remove existing rules.

- [ ] **Step 7: Run** `bundle exec rspec spec/requests/operator_standings_spec.rb spec/views/game_passings_spec.rb spec/requests/interventions_spec.rb spec/requests/operator_skip_spec.rb spec/requests/gated_standings_spec.rb spec/stylesheets/token_discipline_spec.rb spec/i18n_spec.rb`, then `bundle exec cucumber features/logs features/game-passing`. Expect all green.

- [ ] **Step 8: Commit:** `git commit -m "Make the operator's standings fit a phone: two-line rows, panel log buttons, sticky control bar"`.

---

### Task 4: Full log and live channel

**Files:**
- Modify: `app/views/logs/show_full_log.html.erb`, `app/views/logs/show_live_channel.html.erb`, `app/controllers/logs_controller.rb` (one preload), `public/stylesheets/screens.css`, `config/locales/*.yml`
- Create: `spec/requests/operator_logs_spec.rb`

**Interfaces — Consumes:** `shared/_live_status`, `.table--compact`.
**Produces:**
- Full log markup:
  - `div#fulllog-live.table-wrap[data-live]` > `table#stats.log-matrix`;
  - level rows `tr.log-level-row`;
  - team cells containing `strong.log-team`;
  - an empty team cell contains `p.log-none`;
  - an accepted answer is followed by `span.log-ok[aria-label]`.
- Live channel: `div#livechannel-live.table-wrap[data-live]` > `table#livechannel.table--cards.table--compact`, with cells `td.lc-time`, `td.lc-team`, `td.lc-level`, `td.lc-code`.
- Keys:
  - `logs.show_full_log.no_answers` = «— нет ответов»;
  - `logs.show_full_log.accepted` = «верно».

- [ ] **Step 1: Write the failing request spec** — `spec/requests/operator_logs_spec.rb`:

```ruby
require "rails_helper"

# The full log and live channel, reworked for a phone. The ✓ must agree with
# the game's own scoring (Level#find_question_by_answer: strip + upcase, quiz
# questions skipped), never with a second rule written here.
describe "the operator's log screens", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.hours.ago)
    g
  end
  let(:team)  { create_team(:captain => create_user) }
  let(:quiet) { create_team(:captain => create_user) }
  let!(:level) { create_level(:game => game, :correct_answer => "Мост") }
  let(:doc) { Nokogiri::HTML(response.body) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def log(answer, who = team)
    create_log(:game => game, :level => level, :team => who, :game_run => game.current_run, :answer => answer)
  end

  def cell_for(name)
    doc.css("table.log-matrix td").find { |td| td.at_css(".log-team")&.text&.strip == name }
  end

  before do
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)
    create_game_passing(:level => level, :team => quiet, :game_run => game.current_run)
    sign_in(author)
  end

  describe "the full log" do
    it "marks an answer the game would accept, including a case and whitespace variant" do
      log("  мост "); log("неверно")
      get show_full_log_path(:game_id => game.id)

      items = cell_for(team.name).css("li")
      accepted = items.select { |li| li.at_css(".log-ok") }.map { |li| li.text.gsub("✓", "").strip }
      expect(accepted.size).to eq(1)
      expect(accepted.first).to end_with("мост")
      expect(items.find { |li| li.text.include?("неверно") }.at_css(".log-ok")).to be_nil
      expect(cell_for(team.name).at_css(".log-ok")["aria-label"]).to eq("верно")
    end

    it "does not mark a quiz level's leftover code the game refuses" do
      question = level.questions.first
      create_option(:question => question, :is_correct => true)
      log("Мост")
      get show_full_log_path(:game_id => game.id)

      expect(cell_for(team.name).at_css(".log-ok")).to be_nil
    end

    it "says a team has no answers on a level" do
      log("неверно")
      get show_full_log_path(:game_id => game.id)

      expect(cell_for(quiet.name).at_css(".log-none").text.strip).to eq("— нет ответов")
      expect(cell_for(quiet.name).at_css("ul")).to be_nil
    end

    it "keeps the title and puts the matrix in a live region" do
      get show_full_log_path(:game_id => game.id)

      expect(response.body).to include("Полный лог ответов")
      live = doc.at_css("[data-live]")
      expect(live["id"]).to eq("fulllog-live")
      expect(live.at_css("table#stats.log-matrix tr.log-level-row")).to be_present
      expect(doc.at_css("[data-live-status]")).to be_present
    end
  end

  describe "the live channel" do
    it "uses the compact card table inside a live region, cells classed for the phone layout" do
      log("мост")
      get show_live_channel_path(:game_id => game.id)

      live = doc.at_css("[data-live]")
      expect(live["id"]).to eq("livechannel-live")
      row = live.at_css("table#livechannel.table--cards.table--compact tbody tr")
      expect(row.css("td").map { |td| td["class"] }).to eq(%w[lc-time lc-team lc-level lc-code])
      expect(row.at_css(".lc-code").text.strip).to eq("мост")
      expect(doc.at_css("[data-live-status]")).to be_present
    end
  end
end
```

  Check `create_option`'s signature in `spec/spec_helpers/fixtures_helper.rb` (around line 201) and adapt the call. The quiz example needs the level's only question to become a quiz question (`Question#quiz?` is `options.any?(&:is_correct)`) while keeping its Answer rows.

- [ ] **Step 2: Run it.** Expect failures.

  Run: `bundle exec rspec spec/requests/operator_logs_spec.rb`

- [ ] **Step 3: Preload options.** In `LogsController#show_full_log`, change `includes(:questions => :answers)` to `includes(:questions => [:answers, :options])`, and extend the comment above it by one sentence: `Level#find_question_by_answer` (the full log's ✓) calls `Question#quiz?`, which reads `options`.

- [ ] **Step 4: Full log markup.** In `show_full_log.html.erb`:
  - `<table id="stats">` → `<table id="stats" class="log-matrix">`.
  - Wrap the table's `<div class="table-wrap">` as `<div class="table-wrap" id="fulllog-live" data-live>`.
  - Add `<%= render "shared/live_status" %>` directly after `<%= render "shared/run_context" %>`.
  - The level header `<tr>` → `<tr class="log-level-row">`.
  - Replace the team cell's body (from `<%= team.name %>` through `</ul>`, keeping the existing explanatory comment) with:

```erb
          <strong class="log-team"><%= team.name %></strong>
          <% team_logs = logs_by_cell.fetch([ team.id, level.id ], []) %>
          <% if team_logs.empty? %>
            <p class="log-none"><%= t("logs.show_full_log.no_answers") %></p>
          <% else %>
            <ul>
            <% team_logs.each do |team_log| %>
              <%# ✓ when the game would accept this answer -- the same method
                  the game credits with (strip + upcase, quiz questions
                  skipped); no second matching rule lives here. %>
              <li><%= team_log.time.strftime("%H:%M:%S") %>&nbsp;<%= team_log.answer %><% if level.find_question_by_answer(team_log.answer) %><span class="log-ok" aria-label="<%= t("logs.show_full_log.accepted") %>">✓</span><% end %></li>
            <% end %>
            </ul>
          <% end %>
```

- [ ] **Step 5: Live channel markup.** In `show_live_channel.html.erb`:
  - Add `<%= render "shared/live_status" %>` after `render "shared/run_context"`.
  - Wrap with `<div class="table-wrap" id="livechannel-live" data-live>`.
  - The table becomes `class="table--cards table--compact"`.
  - Each `<td>` gains `class="lc-time"`, `"lc-team"`, `"lc-level"`, `"lc-code"` in order. Keep the `data-label`s, which desktop does not show and which `table--cards` still uses at other widths.

- [ ] **Step 6: Keys** under the existing `logs:` → `show_full_log:` mapping (ru.yml ~990):

| key | ru | en | uk | be | pl | tr | ka |
|---|---|---|---|---|---|---|---|
| no_answers | — нет ответов | — no answers | — немає відповідей | — няма адказаў | — brak odpowiedzi | — yanıt yok | — პასუხები არ არის |
| accepted | верно | accepted | правильно | правільна | poprawnie | kabul edildi | სწორია |

- [ ] **Step 7: CSS.** Append to `screens.css`:

```css
/* --- Full log on a phone (logs/show_full_log) -------------------------------
 * Desktop keeps the levels x teams grid. Below 48rem the same markup
 * restacks: each level row is a section heading, each team cell an indented
 * block -- no inner sideways scroller, whatever the team count. */
.log-team { display: block; }
.log-ok { color: var(--go); font-weight: 600; margin-left: var(--space-1); }
.log-none { color: var(--text-dim); font-size: var(--text-sm); }

@media (max-width: 47.99rem) {
  .log-matrix, .log-matrix tbody, .log-matrix tr, .log-matrix td { display: block; width: auto; }
  .log-matrix td { border: 0; padding: var(--space-1) 0 var(--space-2) var(--space-3);
                   overflow-wrap: anywhere; }
  .log-matrix .log-level-row td { padding: var(--space-4) 0 var(--space-1);
                                  border-top: 1px solid var(--border); }
  .log-matrix ul { list-style: none; }

  /* Live channel as two lines: time · team / level — code. */
  #livechannel .lc-time, #livechannel .lc-team,
  #livechannel .lc-level, #livechannel .lc-code { display: inline; padding: 0; }
  #livechannel .lc-team::before { content: " · "; color: var(--text-dim); }
  #livechannel .lc-level::before { content: "\A"; white-space: pre; }
  #livechannel .lc-code::before { content: " — "; color: var(--text-dim); }
  #livechannel tr { padding: var(--space-2) var(--space-3); margin-bottom: var(--space-2); }
}
```

- [ ] **Step 8: Run:**
  - `bundle exec rspec spec/requests/operator_logs_spec.rb spec/requests/full_log_queries_spec.rb spec/requests/full_log_scope_spec.rb spec/requests/gated_log_scope_spec.rb spec/requests/log_pagination_spec.rb spec/requests/run_scoped_logs_spec.rb spec/views/logs_spec.rb spec/controllers/logs spec/stylesheets/token_discipline_spec.rb spec/i18n_spec.rb`
  - then `bundle exec cucumber features/logs features/games/game_full_log.feature`

  Expect all green. If `full_log_queries_spec` now grows with levels, the ✓ check is querying per cell: find the uncached association and preload it. Do not loosen the spec.

- [ ] **Step 9: Commit:** `git commit -m "Restack the full log and live channel for a phone; mark accepted answers"`.

---

### Task 5: Results live region

**Files:**
- Modify: `app/views/game_passings/show_results.html.erb`
- Create: `spec/requests/operator_results_spec.rb`

**Interfaces — Consumes:** `shared/_live_status`. **Produces:** `div#results-live.table-wrap[data-live]` around `table#results`.

- [ ] **Step 1: Failing spec** — `spec/requests/operator_results_spec.rb`:

```ruby
require "rails_helper"

describe "the results screen", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author); set_game_schedule!(g, :starts_at => 1.hour.ago); g }
  let!(:level) { create_level(:game => game) }

  it "refreshes the results table in place" do
    passing = create_game_passing(:level => level)
    passing.update_column(:finished_at, Time.now)
    put login_path, :params => { :email => author.email, :password => "1234" }

    get "/stats/show_results/#{game.id}"

    doc = Nokogiri::HTML(response.body)
    live = doc.at_css("[data-live]")
    expect(live["id"]).to eq("results-live")
    expect(live.at_css("table#results")).to be_present
    expect(doc.at_css("[data-live-status]")).to be_present
  end
end
```

- [ ] **Step 2: Run it.** Expect failure.

- [ ] **Step 3: Implement:**
  - `<div class="table-wrap">` around `#results` becomes `<div class="table-wrap" id="results-live" data-live>`;
  - add `<%= render "shared/live_status" %>` directly before it.

- [ ] **Step 4: Run** `bundle exec rspec spec/requests/operator_results_spec.rb spec/views/game_passings_spec.rb`, then `bundle exec cucumber features/game-passing`. Expect green.

- [ ] **Step 5: Commit:** `git commit -m "Refresh the results table in place"`.

---

### Task 6: Standings layout spec

**Files:** Create `spec/layout/operator_standings_layout_spec.rb`.
**Consumes:** Tasks 1–3, and `LayoutMeasurement#measure(html, width, height, script, tmp_name:)`. Read `spec/support/layout_measurement.rb` and `spec/layout/home_layout_spec.rb` first and follow their conventions: how the HTML is produced, how `RESULT` is returned, how the theme is set.

- [ ] **Step 1: Write the spec.** Fixture: a running game whose author has 8 levels and 12 teams with realistic Russian names, one of them `"Оченьдлинноеназваниекомандыбезпробеловкотороенедолжнорасширятьстраницу"`, each with a passing on varying levels. The game is unpaused for the default contexts and paused for a "paused" context. Sign in as the author and `get game_stats_path(game)`.

  The live-region script will not load from the `file://` copy the harness renders, so the probe unhides `[data-live-status]` and gives its stamp sample text. That measures the bar at its real, fullest height.

  Probe (run after `data-theme` is set):

```js
document.documentElement.setAttribute("data-theme", THEME);
var status = document.querySelector("[data-live-status]");
if (status) { status.hidden = false;
  status.querySelector("[data-live-stamp]").textContent = "Обновлено 12 с назад";
  status.querySelector("[data-live-toggle]").textContent = "Пауза обновления"; }
var vw = document.documentElement.clientWidth;
function hit(el) { var r = el.getBoundingClientRect(); if (r.width === 0) return false;
  var t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return !!t && (t === el || el.contains(t)); }
var pause = document.querySelector(".opbar button");
var pauseTop = hit(pause);
window.scrollTo(0, document.documentElement.scrollHeight);
var pauseBottom = hit(pause);
window.scrollTo(0, 0);
var rows = Array.prototype.slice.call(document.querySelectorAll("#stats tbody tr"));
var firstDetails = document.querySelector("#stats details"); firstDetails.open = true;
var panelControls = Array.prototype.slice.call(firstDetails.querySelectorAll(".team-panel .btn, .team-panel select, .team-panel button, .team-panel input[type=submit]"));
var scrollers = Array.prototype.slice.call(document.querySelectorAll("body *")).filter(function (el) {
  var s = getComputedStyle(el); return (s.overflowX === "auto" || s.overflowX === "scroll") && el.scrollWidth > el.clientWidth + 1; });
var RESULT = {
  theme: document.documentElement.getAttribute("data-theme"),
  rowCount: rows.length,
  tallRows: rows.map(function (r) { return Math.round(r.getBoundingClientRect().height); }).filter(function (h) { return h > 90; }),
  pauseTop: pauseTop, pauseBottom: pauseBottom,
  panelControlCount: panelControls.length,
  shortControls: panelControls.filter(function (el) { return el.getBoundingClientRect().height < 43.5; }).map(function (el) { return el.textContent.trim() || el.tagName; }),
  logCellDisplays: Array.prototype.slice.call(document.querySelectorAll("#stats .standings-log")).map(function (el) { return getComputedStyle(el).display; }).filter(function (v, i, a) { return a.indexOf(v) === i; }),
  disclosureInside: Array.prototype.slice.call(document.querySelectorAll(".team-disclosure")).every(function (el) { return el.getBoundingClientRect().right <= vw + 0.5; }),
  innerScrollers: scrollers.map(function (el) { return (el.id || el.className || el.tagName) + ":" + el.scrollWidth; }),
  hOverflow: document.documentElement.scrollWidth - vw
};
```

  Contexts and examples:
  - `%w[dark light]` × `{ "phone" => [390, 680], "small phone" => [375, 553], "desktop" => [1280, 800] }`, plus one `paused, dark, 390×680` context.
  - Every context:
    - "measured the theme it was asked for" (`theme`, `rowCount == 12`);
    - "Pause/Resume can be tapped at the top and the bottom of the scroll" (`pauseTop && pauseBottom`);
    - "every control in an opened panel is at least 44px" (`panelControlCount >= 3`, `shortControls == []`);
    - "does not scroll sideways, on the page or inside anything" (`hOverflow == 0`, `innerScrollers == []`).

      On desktop, `innerScrollers` may legitimately include nothing. If the desktop table legitimately scrolls inside `.table-wrap` at 1280, report it instead of weakening the assertion.
  - Phone contexts only:
    - "keeps each team to a short row" (`tallRows == []`);
    - "hides the frozen log-link cells and keeps the panel button on screen" (`logCellDisplays == ["none"]`, `disclosureInside`).
  - Desktop only: "keeps the log-link columns on desktop" (`logCellDisplays == ["table-cell"]`).

  Tag the describe `:layout`, `type: :request`, like the existing layout specs.

- [ ] **Step 2: Run** `LAYOUT_SPECS=1 bundle exec rspec spec/layout/operator_standings_layout_spec.rb` (foreground). If an example fails, fix the CSS from Task 3 in `screens.css`, never the probe, and put the fix in its own commit with the reason.

- [ ] **Step 3: Mutation-check,** reverting each precisely:
  - remove `position: sticky` from `.opbar` → the "bottom of the scroll" example fails at 390;
  - remove `.standings .standings-log { display: none; }` → the hidden-cells example fails;
  - remove `margin-right: 48%` from `.standings-team` while the long-name team is present → either the overflow example or the disclosure-inside example fails (record which; if neither, the long-name fixture is not exercising the overlap, so fix the fixture).

- [ ] **Step 4: Commit:** `git commit -m "Measure the operator standings on phones and desktop"`.

---

### Task 7: Logs and overflow-only screens layout spec

**Files:** Create `spec/layout/operator_logs_layout_spec.rb`.
**Consumes:** Tasks 1, 2, 4 and 5; the harness as in Task 6.

- [ ] **Step 1: Write the spec.** One running game with 8 levels and 12 teams (one with the long unbroken name from Task 6). There are about 60 log rows, including:
  - an answer `"Оченьдлинныйответбезпробеловкоторыйнедолженрасширятьэкран"`;
  - a level named `"Оченьдлинноеназваниеуровнябезпробелов"`.

  Pages, each signed in as the author unless noted:
  - full log `show_full_log_path(:game_id => game.id)`;
  - live channel `show_live_channel_path(:game_id => game.id)`;
  - level log `show_level_log_path(:game_id => game.id, :team_id => long_team.id)`;
  - game log `show_game_log_path(:game_id => game.id, :team_id => long_team.id)`;
  - the game page `game_path(game)`;
  - the admin entries console as a superadmin. Find its path helper with `bin/rails routes -g entries`.

  Probe:

```js
document.documentElement.setAttribute("data-theme", THEME);
var vw = document.documentElement.clientWidth;
var scrollers = Array.prototype.slice.call(document.querySelectorAll("body *")).filter(function (el) {
  var s = getComputedStyle(el); return (s.overflowX === "auto" || s.overflowX === "scroll") && el.scrollWidth > el.clientWidth + 1; });
var teamCells = Array.prototype.slice.call(document.querySelectorAll("table.log-matrix tr:not(.log-level-row) td"));
var firstTeamRow = document.querySelector("table.log-matrix tr:not(.log-level-row)");
var RESULT = {
  theme: document.documentElement.getAttribute("data-theme"),
  hOverflow: document.documentElement.scrollWidth - vw,
  innerScrollers: scrollers.map(function (el) { return (el.id || el.className || el.tagName) + ":" + el.scrollWidth + "/" + el.clientWidth; }),
  narrowTeamCells: teamCells.filter(function (td) { return td.getBoundingClientRect().width < vw * 0.8; }).length,
  teamCellCount: teamCells.length,
  desktopGridCells: firstTeamRow ? Array.prototype.slice.call(firstTeamRow.children).filter(function (td) { return getComputedStyle(td).display === "table-cell"; }).length : 0
};
```

  Contexts and examples:
  - Each page × `%w[dark light]` × phone 390×680 and desktop 1280×800:
    - "measured the theme";
    - "does not scroll sideways at the page level" (`hOverflow == 0`).
  - Phone only: "no inner sideways scroller" (`innerScrollers == []`).
  - Full log, phone: "every team block is full width" (`teamCellCount > 0`, `narrowTeamCells == 0`).
  - Full log, desktop: "is still a grid" (`desktopGridCells > 1`). Desktop may legitimately have the full log scroll inside `.table-wrap` at 12 teams, so the inner-scroller example is phone-only.

- [ ] **Step 2: Run** `LAYOUT_SPECS=1 bundle exec rspec spec/layout/operator_logs_layout_spec.rb` (foreground). A page that still overflows on a phone after Tasks 2, 4 and 5 is a real defect.
  - Find the element: probe `document.querySelectorAll("body *")` for `getBoundingClientRect().right > vw`.
  - Fix it in CSS in its own commit, with the reason. A flex item typically needs `min-width: 0`; a `ul.game-list` name needs `overflow-wrap: anywhere`.
  - Never weaken the assertion.

- [ ] **Step 3: Mutation-check,** reverting each precisely:
  - remove the `display: block` restack line for `.log-matrix` → full-log examples fail at 390;
  - remove `overflow-wrap: break-word` from `.main` → at least one of the level log, game log or game page overflow examples fails at 390. Record which.

- [ ] **Step 4: Commit:** `git commit -m "Measure the operator log screens and overflow-only pages"`.

---

### Task 8: Documentation

**Files:** Modify `CLAUDE.md`. **Consumes:** the orchestrator's measured RSpec count, given in the dispatch.

- [ ] **Step 1: Edit:**
  - **Layout section.** In "Layout is invisible to both suites", update the spec list: `spec/layout/` holds **eight** specs. Add `operator_standings_layout_spec.rb` (two-line rows ≤90px on phones, Pause tappable at both scroll ends, panel controls ≥44px, frozen log-link cells hidden on phones only, no sideways scroll) and `operator_logs_layout_spec.rb` (full log restacked on phones and still a grid on desktop, live channel, per-team logs, game page, admin entries: no sideways scroll). A new screen gets a ninth file.
  - **i18n leaf count.** Measure it with the CLAUDE.md one-liner (expected 1095 = 1088 + 7) and add a one-sentence history entry.
  - **RSpec count.** Use the orchestrator's number, with a one-line parenthetical.
  - **New section.** Add a short "## Operator screens on a phone" section after "## The home page", covering:
    - `live_region.js` + `shared/_live_status`: the 20 s poll; the three holds and the re-check after fetch; a response without the region keeps the old content; nothing changes without JS.
    - The hidden log-link cells on the standings screen and why. `features/logs/log.feature:29-61` clicks them; rack-test ignores external CSS. Never hide them with an inline style, a `hidden` attribute or by moving them into the closed `<details>`. This is the same construction as the locale dropdown.
    - `.table--compact` and the `.ops`/`.opbar` order trick.
    - The full log's ✓ uses `Level#find_question_by_answer`, so it cannot disagree with scoring, which is why the controller preloads `:options`.

- [ ] **Step 2: Commit:** `git commit -m "Document the operator screens on a phone and the new counts"`.

---

### Task 9: Verification and PR (orchestrator)

- [ ] Each step alone, on a fresh isolated DB:
  - full RSpec (record the count and hand it to Task 8);
  - `LAYOUT_SPECS=1 bundle exec rspec spec/layout` (eight files);
  - `bin/measure-play-screen`;
  - `bundle exec cucumber`;
  - the inherited-contract run, expecting 228 (226 passed, 2 undefined) / 2325;
  - `git diff origin/master -- features/` must be empty.
- [ ] Before/after screenshots of the in-scope screens at 390 and 1280. The "before" set exists already in the session scratchpad `opshots/`.
- [ ] Push and open the PR "Run a game from a phone: operator screens".
