# UI Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 2008 desktop-only interface with a dark-first, responsive one that works on a phone in the street at night and on a laptop under time pressure — without changing a single word of visible copy.

**Architecture:** CSS custom properties in plain stylesheets under `public/stylesheets/`, no build step. Dark is the default theme and light is the same tokens with different values, switched by a `data-theme` attribute on `<html>`. A component layer lifts all 60 views at once; four screens then get bespoke layout work on top of it.

**Tech Stack:** Ruby 3.3.12, Rails 8.0.5.1, hand-written CSS (custom properties, Grid, `clamp()`), vanilla JS. No Node, no Tailwind, no asset pipeline.

## Global Constraints

- Ruby is pinned to `3.3.12` and Rails to `8.0.5.1`. Do not change either.
- rbenv is not on PATH in non-login shells. Prefix every Ruby command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never create, edit or delete any file under `features/`.** Those `.feature` files are the frozen contract the Merb→Rails port was validated against.
- **No visible copy changes anywhere.** This refactor moves markup and adds CSS. Every Russian link label, button label and heading stays byte-identical, because 234 cucumber scenarios click on that text. If a label seems wrong, that is out of scope.
- **Do not add a build step.** No `package.json`, no Node, no Tailwind, no asset-pipeline gem. Stylesheets are plain CSS files in `public/stylesheets/`, linked from the layouts.
- Existing gates must stay green at every task: `bundle exec rspec` is **651 examples, 0 failures, 6 pending**; `bundle exec cucumber` is **234 scenarios (2 pre-existing "undefined" placeholders), 2362 steps**.
- **Dark is the default. The light theme is in scope, not a stretch goal** — every component is authored and contrast-checked in both, and no task is complete with one of them unexamined.
- **Ember palette, with go/time/danger separated by treatment rather than hue:** go is the only filled warm button; a countdown is never filled, because it is information rather than an action; danger is always outlined, always behind a confirm, and never adjacent to a go button.
- Tap targets are **44px minimum** on interactive elements.
- Both themes must meet **WCAG AA** on body text and interactive elements.
- Hash rockets (`:key => value`) are the surrounding style in Ruby. ERB follows each file's existing conventions.

### The DOM contract — these selectors are load-bearing

Verified against the suite while writing this plan. Everything else in the markup is free to change.

| Selector | Where it is required | Why |
|---|---|---|
| `#coming` | `app/views/dashboard/_coming_games.html.erb` | Named **inside a frozen `.feature` file** (`в блоке "coming"`) |
| `#mygames` | `app/views/dashboard/_my_games.html.erb` | Named **inside a frozen `.feature` file** (`в блоке "mygames"`) |
| `table#stats` | `app/views/game_passings/index.html.erb` | `features/game-passing/steps/…:83` reads `tableish('table#stats tr', 'td,th')` |
| `#locale-switcher` | `app/views/layouts/_header.html.erb` | `features/i18n/steps/…:58` does `within("#locale-switcher")` |
| `#LevelHintsContainer`, `#LevelHintCountdownContainer`, `#LevelHintCountdownTimerText`, `#LevelHintCountdownLoadIndicator` | `app/views/game_passings/show_current_level.html.erb` | `level_hint_updater.js:96-99` writes into them. **Nothing tests these** — rename one and hints silently stop mid-game |

`#coming` and `#mygames` **cannot change** — the id lives in a file nobody may edit. `table#stats` and `#locale-switcher` live in editable step definitions, but keeping them costs nothing and removes a whole class of risk.

### Other verified facts

- There is **no asset pipeline**: no propshaft, no sprockets, no `package.json`, no `app/assets`. Both layouts link `/stylesheets/master.css` directly.
- Two layouts exist: `application.html.erb` (header + left menu + main) and `in_game.html.erb` (header + main, no menu). Both already declare `<meta name="viewport" content="width=device-width, initial-scale=1">`.
- `public/javascripts/` holds jQuery **1.3.2** plus `level_hint_updater.js`, calendar, autocomplete and thickbox. **Do not touch or upgrade jQuery** — the hint poller depends on it and replacing it is a separate project.
- `spec/views/` has 15 spec files rendering real templates, including `layouts_spec.rb`. They will catch a broken partial.
- `master.css` is 277 lines with zero media queries. `calendar.css`, `jquery.autocomplete.css` and `thickbox.css` belong to vendored jQuery plugins — leave them alone.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `public/stylesheets/tokens.css` | Colour, type, spacing, radius custom properties for both themes |
| `public/stylesheets/base.css` | Reset, document defaults, typography |
| `public/stylesheets/layout.css` | Page shells, drawer, grid |
| `public/stylesheets/components.css` | Buttons, forms, tables, flash, cards, panels |
| `public/stylesheets/screens.css` | The four bespoke screens |
| `public/javascripts/theme.js` | Theme resolution and toggle |
| `public/javascripts/drawer.js` | Mobile navigation drawer |
| `spec/requests/ui_shell_spec.rb` | Theme control, drawer markup, no-JS fallback |
| `spec/requests/ui_contract_spec.rb` | The four load-bearing selectors survive |

**Modified:**

| File | Change |
|---|---|
| `app/views/layouts/application.html.erb` | Stylesheet links, theme boot, drawer, grid shell |
| `app/views/layouts/in_game.html.erb` | Same, minus the menu; focused play shell |
| `app/views/layouts/_header.html.erb` | Theme toggle; `#locale-switcher` preserved |
| `app/views/layouts/_left_menu.html.erb` | Drawer-compatible markup |
| `app/views/game_passings/show_current_level.html.erb` | Pinned bar |
| `app/views/game_passings/index.html.erb` | Read-only list + detail panel |
| `app/views/dashboard/*` | Layout; `#coming` and `#mygames` preserved |
| `app/views/games/*`, `app/views/admin/*` | Layout on top of components |
| `public/stylesheets/master.css` | Deleted in Task 8 once nothing references it |

---

### Task 1: Design tokens and the theme switch

**Files:**
- Create: `public/stylesheets/tokens.css`, `public/javascripts/theme.js`, `spec/requests/ui_shell_spec.rb`
- Modify: `app/views/layouts/application.html.erb`, `app/views/layouts/in_game.html.erb`, `app/views/layouts/_header.html.erb`, `config/locales/{ru,en,uk,ka}.yml`

**Interfaces:**
- Produces: CSS custom properties consumed by every later task — `--bg`, `--surface`, `--surface-2`, `--border`, `--text`, `--text-dim`, `--go`, `--go-ink`, `--time`, `--danger`, `--focus`, `--space-1…6`, `--radius`, `--font-ui`, `--font-mono`; and `data-theme="dark|light"` on `<html>`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/ui_shell_spec.rb
require "rails_helper"

describe "the UI shell", type: :request do
  it "boots with a resolved theme and links the token stylesheet" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/stylesheets/tokens.css")
    # The boot script must run before first paint, inline in <head>, or the
    # page flashes the wrong theme on every load.
    expect(response.body).to include("/javascripts/theme.js")
  end

  it "offers a theme toggle" do
    get login_path

    expect(response.body).to include('id="theme-toggle"')
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/ui_shell_spec.rb
```

Expected: FAIL — the body contains none of those strings.

- [ ] **Step 3: Write the tokens**

```css
/* public/stylesheets/tokens.css
 *
 * Every colour in the application resolves through these. Dark is the
 * default; light is the same token names with different values, so no
 * component is ever authored twice.
 *
 * Ember palette. go / time / danger are neighbours on the colour wheel, so
 * they are ALSO separated by treatment -- see components.css. Never rely on
 * hue alone to tell a countdown from a destructive button.
 */
:root,
:root[data-theme="dark"] {
  --bg:         #12100e;
  --surface:    #1c1917;
  --surface-2:  #241f1c;
  --border:     #332e29;
  --text:       #f5f1ed;
  --text-dim:   #9a8f85;

  --go:         #fbbf24;
  --go-ink:     #1a1205;   /* text on a filled go button */
  --time:       #fb923c;
  --danger:     #dc5555;
  --focus:      #fbbf24;
}

:root[data-theme="light"] {
  --bg:         #faf8f6;
  --surface:    #ffffff;
  --surface-2:  #f3efec;
  --border:     #ddd5cd;
  --text:       #1c1917;
  --text-dim:   #6b6259;

  /* Darker than the dark theme's values: the same amber that reads clearly
     on #12100e fails AA on white. */
  --go:         #a86a08;
  --go-ink:     #ffffff;
  --time:       #b45309;
  --danger:     #b42318;
  --focus:      #a86a08;
}

:root {
  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-5: 24px;
  --space-6: 40px;

  --radius:    8px;
  --radius-sm: 6px;

  --font-ui:   system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;

  --tap: 44px;
}
```

- [ ] **Step 4: Write the theme script**

```javascript
// public/javascripts/theme.js
//
// Runs inline in <head>, before first paint. A deferred script would let the
// page render in the wrong theme and then swap, which is worse than having no
// toggle at all.
//
// localStorage rather than a user column, deliberately: a theme is a
// device-and-lighting choice, not a personal one -- the same person wants dark
// in the street at night and light at a desk at noon -- and this also works
// for signed-out visitors with no migration.
(function () {
  var stored = null;
  try { stored = localStorage.getItem("theme"); } catch (e) { /* private mode */ }

  var prefersLight = window.matchMedia &&
                     window.matchMedia("(prefers-color-scheme: light)").matches;

  document.documentElement.setAttribute(
    "data-theme", stored || (prefersLight ? "light" : "dark")
  );

  window.toggleTheme = function () {
    var next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("theme", next); } catch (e) { /* ignore */ }
  };
})();
```

- [ ] **Step 5: Wire it into both layouts**

In `application.html.erb` and `in_game.html.erb`, **add these below the existing
`master.css` link — do not replace it.** `master.css` still styles the whole application
and is not retired until Task 8:

```erb
    <link rel="stylesheet" href="/stylesheets/tokens.css">
    <link rel="stylesheet" href="/stylesheets/base.css">
    <link rel="stylesheet" href="/stylesheets/layout.css">
    <link rel="stylesheet" href="/stylesheets/components.css">
    <link rel="stylesheet" href="/stylesheets/screens.css">
    <script src="/javascripts/theme.js"></script>
```

`base.css`, `layout.css`, `components.css` and `screens.css` do not exist yet — create each as an empty file with a one-line comment naming its responsibility, so the links resolve. Later tasks fill them.

Keep `master.css` linked for now; it is deleted in Task 8 once nothing depends on it.

- [ ] **Step 6: Add the toggle to the header**

In `app/views/layouts/_header.html.erb`, above the `#locale-switcher` div:

```erb
<%# aria-pressed is not used: the control does not have an on/off meaning so
    much as a "switch to the other one" meaning, and the label says which. %>
<button type="button" id="theme-toggle" onclick="toggleTheme()">
  <%= t("layout.header.theme") %>
</button>
```

**Do not modify anything inside `#locale-switcher`.** That id is asserted by a step definition.

- [ ] **Step 7: Add the key to all four locale files**

`ru.yml`, under `layout: header:` — `theme: "Тема"`. `en.yml` — `theme: "Theme"`. `uk.yml` — `theme: "Тема"`. `ka.yml` — `theme: "თემა"`.

- [ ] **Step 8: Run the spec, then both gates**

```bash
bundle exec rspec spec/requests/ui_shell_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **653 examples** (651 + 2), 0 failures, 6 pending; cucumber unchanged at 234 scenarios / 2362 steps.

- [ ] **Step 9: Commit**

```bash
git add public/stylesheets public/javascripts/theme.js app/views/layouts config/locales spec/requests/ui_shell_spec.rb
git commit -m "Add design tokens and a persisted dark/light theme"
```

---

### Task 2: Base styles and the responsive shell

**Files:**
- Modify: `public/stylesheets/base.css`, `public/stylesheets/layout.css`, `app/views/layouts/application.html.erb`, `app/views/layouts/in_game.html.erb`, `app/views/layouts/_left_menu.html.erb`, `config/locales/{ru,en,uk,ka}.yml`
- Create: `public/javascripts/drawer.js`
- Test: `spec/requests/ui_shell_spec.rb` (extend)

**Interfaces:**
- Consumes: all tokens from Task 1.
- Produces: `.page` grid shell, `.drawer` / `#drawer-toggle`, `.main`. Later tasks lay content inside `.main`.

- [ ] **Step 1: Write the failing spec**

Append inside the existing `describe` in `spec/requests/ui_shell_spec.rb`:

```ruby
  describe "the navigation drawer" do
    let(:user) { create_user }

    def sign_in(u)
      put login_path, :params => { :email => u.email, :password => "1234" }
    end

    it "renders the menu inside a labelled drawer" do
      sign_in(user)

      get dashboard_path

      expect(response.body).to include('id="drawer"')
      expect(response.body).to include('id="drawer-toggle"')
    end

    # A drawer that only opens with JavaScript is a site that does not work
    # without JavaScript -- including the login page. The checkbox pattern
    # below opens it with CSS alone; drawer.js only adds niceties.
    it "keeps the menu reachable with no JavaScript" do
      sign_in(user)

      get dashboard_path

      expect(response.body).to include('id="drawer-state"')
      expect(response.body).to include(dashboard_path)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/ui_shell_spec.rb
```

Expected: FAIL — no drawer markup.

- [ ] **Step 3: Write base.css**

```css
/* public/stylesheets/base.css -- reset and document defaults. */
*, *::before, *::after { box-sizing: border-box; }

body, h1, h2, h3, h4, p, ul, ol, figure, fieldset, legend {
  margin: 0;
  padding: 0;
}

html { -webkit-text-size-adjust: 100%; }

body {
  background: var(--bg);
  color: var(--text);
  font-family: var(--font-ui);
  /* Scales with the viewport instead of jumping at breakpoints. The floor is
     16px because iOS zooms a focused input below that. */
  font-size: clamp(16px, 0.95rem + 0.2vw, 18px);
  line-height: 1.6;
  min-height: 100vh;
}

h1 { font-size: clamp(1.6rem, 1.3rem + 1.4vw, 2.4rem); line-height: 1.2; font-weight: 650; }
h2 { font-size: clamp(1.2rem, 1.05rem + 0.7vw, 1.6rem); line-height: 1.25; font-weight: 600; }
h3 { font-size: 1.05rem; font-weight: 600; color: var(--text); }

a { color: var(--go); text-decoration: none; }
a:hover { text-decoration: underline; }

/* Visible on every focusable element, in both themes. Removing focus rings
   makes the app unusable by keyboard; this one is deliberately loud. */
:focus-visible {
  outline: 2px solid var(--focus);
  outline-offset: 2px;
  border-radius: var(--radius-sm);
}

ul { list-style: none; }
img { max-width: 100%; height: auto; }
```

- [ ] **Step 4: Write layout.css**

```css
/* public/stylesheets/layout.css -- page shells and the drawer. */

.page {
  display: grid;
  grid-template-columns: 1fr;
  min-height: 100vh;
}

.topbar {
  display: flex;
  align-items: center;
  gap: var(--space-3);
  padding: var(--space-3) var(--space-4);
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  position: sticky;
  top: 0;
  z-index: 20;
}

.main {
  padding: var(--space-5) var(--space-4);
  max-width: 72rem;
  width: 100%;
  margin: 0 auto;
}

/* The drawer is driven by a hidden checkbox so it opens with CSS alone.
   drawer.js only adds Escape-to-close and focus handling -- without it the
   navigation still works, which matters because this markup is on the login
   page too. */
#drawer-state { position: absolute; opacity: 0; pointer-events: none; }

#drawer-toggle {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: var(--tap);
  min-height: var(--tap);
  background: none;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  color: var(--text);
  font-size: 1.2rem;
  cursor: pointer;
}

#drawer {
  position: fixed;
  inset: 0 auto 0 0;
  width: min(82vw, 20rem);
  padding: var(--space-4);
  background: var(--surface);
  border-right: 1px solid var(--border);
  transform: translateX(-100%);
  transition: transform 0.18s ease;
  z-index: 30;
  overflow-y: auto;
}

#drawer-state:checked ~ .page #drawer { transform: translateX(0); }

.drawer-scrim {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.18s ease;
  z-index: 25;
}

#drawer-state:checked ~ .page .drawer-scrim { opacity: 1; pointer-events: auto; }

/* From tablet up the menu is simply always there and the toggle disappears. */
@media (min-width: 60rem) {
  .page { grid-template-columns: 16rem 1fr; grid-template-areas: "top top" "nav main"; }
  .topbar { grid-area: top; }
  #drawer-toggle, .drawer-scrim { display: none; }
  #drawer {
    grid-area: nav;
    position: static;
    transform: none;
    width: auto;
    border-right: 1px solid var(--border);
  }
  .main { grid-area: main; }
}

/* The play shell: no menu, no max-width, room for a pinned bar. */
.page--focused { grid-template-columns: 1fr; }
.page--focused .main { max-width: 44rem; padding-bottom: 12rem; }

@media (prefers-reduced-motion: reduce) {
  #drawer, .drawer-scrim { transition: none; }
}
```

- [ ] **Step 5: Write drawer.js**

```javascript
// public/javascripts/drawer.js
//
// Progressive enhancement only. The drawer opens and closes with CSS via a
// hidden checkbox (see layout.css); this adds Escape-to-close and closes it
// after following a link. If this file fails to load, navigation still works.
(function () {
  var state = document.getElementById("drawer-state");
  if (!state) { return; }

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { state.checked = false; }
  });

  var drawer = document.getElementById("drawer");
  if (drawer) {
    drawer.addEventListener("click", function (e) {
      if (e.target.tagName === "A") { state.checked = false; }
    });
  }
})();
```

- [ ] **Step 6: Restructure `application.html.erb`'s body**

```erb
  <body>
    <input type="checkbox" id="drawer-state" aria-hidden="true" tabindex="-1">

    <div class="page">
      <header class="topbar">
        <label for="drawer-state" id="drawer-toggle" role="button"
               aria-label="<%= t("layout.header.menu") %>">☰</label>
        <%= render "layouts/header" %>
      </header>

      <label for="drawer-state" class="drawer-scrim" aria-hidden="true"></label>

      <nav id="drawer" aria-label="<%= t("layout.header.menu") %>">
        <%= render "layouts/left_menu" %>
      </nav>

      <main class="main">
        <% flash.each do |type, message| %>
          <p class="flash flash--<%= type %>"><%= message %></p>
        <% end %>
        <%= yield %>
      </main>
    </div>

    <script src="/javascripts/drawer.js" defer></script>
  </body>
```

The `<br />`, `<hr />` and the `#header-container` / `#left-container` / `#main-container` wrappers go. Note the flash moves **inside** `.main` — it was above the fold in a way that pushed content down on every notice.

- [ ] **Step 7: Restructure `in_game.html.erb`'s body**

Same, without the drawer, scrim or nav, and with `class="page page--focused"`. A player mid-task gets no menu.

```erb
  <body>
    <div class="page page--focused">
      <header class="topbar"><%= render "layouts/header" %></header>
      <main class="main">
        <% flash.each do |type, message| %>
          <p class="flash flash--<%= type %>"><%= message %></p>
        <% end %>
        <%= yield %>
      </main>
    </div>
  </body>
```

- [ ] **Step 8: Add the menu label to all four locale files**

Under `layout: header:` — ru `menu: "Меню"`, en `menu: "Menu"`, uk `menu: "Меню"`, ka `menu: "მენიუ"`.

- [ ] **Step 9: Run the specs, then both gates**

```bash
bundle exec rspec spec/requests/ui_shell_spec.rb spec/views/layouts_spec.rb spec/i18n_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **655 examples** (653 + 2), 0 failures, 6 pending; cucumber unchanged. Cucumber drives every page through this shell — if it moves, the shell broke a link the suite depends on.

- [ ] **Step 10: Commit**

```bash
git add public/stylesheets public/javascripts/drawer.js app/views/layouts config/locales spec/requests/ui_shell_spec.rb
git commit -m "Replace the floated shell with a responsive grid and a drawer"
```

---

### Task 3: The component layer

**Files:**
- Modify: `public/stylesheets/components.css`
- Test: `spec/requests/ui_contract_spec.rb` (create)

**Interfaces:**
- Consumes: tokens from Task 1.
- Produces: `.btn`, `.btn--go`, `.btn--danger`, `.field`, `.table-wrap`, `.flash`, `.card`, `.panel`, `.countdown`, `.tag`. Tasks 4–8 use these instead of writing new CSS.

This is the task that lifts the other ~50 views without touching them.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/ui_contract_spec.rb
require "rails_helper"

# The four selectors below are load-bearing. Two are named inside frozen
# .feature files and cannot change at all; two are named in step definitions
# which are editable, but keeping them removes a class of risk for free.
describe "the DOM contract the acceptance suite depends on", type: :request do
  let(:author) { create_user }

  def sign_in(u)
    put login_path, :params => { :email => u.email, :password => "1234" }
  end

  it "keeps #locale-switcher in the header" do
    get login_path
    expect(response.body).to include('id="locale-switcher"')
  end

  it "keeps #coming and #mygames on the dashboard" do
    sign_in(author)

    get dashboard_path

    expect(response.body).to include('id="coming"')
    expect(response.body).to include('id="mygames"')
  end

  it "keeps table#stats on the live stats page" do
    game = create_game(:author => author, :is_draft => false)
    game.update_column(:starts_at, 1.hour.ago)
    create_game_passing(:level => create_level(:game => game))
    sign_in(author)

    get game_stats_path(game)

    expect(response.body).to match(/<table[^>]*id="stats"/)
  end
end
```

- [ ] **Step 2: Run it to verify it passes already**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/ui_contract_spec.rb
```

Expected: **PASS**, all 3. This spec is unusual — it is a regression guard written *before* the markup changes that could break it, so it must be green now and stay green through Tasks 4–8. If it fails now, a previous task already broke the contract; stop and fix that first.

- [ ] **Step 3: Write components.css**

```css
/* public/stylesheets/components.css
 *
 * Shared vocabulary. Views compose these; they do not write their own CSS.
 * If a view needs something not here, add it here rather than inline -- a
 * one-off style is a sign the system is missing a component.
 */

/* --- Buttons -------------------------------------------------------------
 * go / time / danger are neighbouring hues in this palette, so they are
 * separated by TREATMENT as well:
 *   .btn--go     filled, the only filled warm control on a screen
 *   .btn--danger outlined, never filled, always behind a confirm
 *   .countdown   not a button at all -- see below
 */
.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: var(--space-2);
  min-height: var(--tap);
  padding: 0 var(--space-4);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: var(--surface-2);
  color: var(--text);
  font: inherit;
  font-weight: 600;
  cursor: pointer;
}

.btn:hover { border-color: var(--text-dim); text-decoration: none; }

.btn--go {
  background: var(--go);
  border-color: var(--go);
  color: var(--go-ink);
}

.btn--danger {
  background: transparent;
  border-color: var(--danger);
  color: var(--danger);
}

.btn--danger:hover { background: color-mix(in srgb, var(--danger) 12%, transparent); }

/* A countdown is information, not an action. Never filled, never bordered --
   if it looks pressable, someone will press it. */
.countdown {
  color: var(--time);
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}

/* --- Forms --------------------------------------------------------------- */
.field { display: block; margin-bottom: var(--space-4); }
.field > label { display: block; margin-bottom: var(--space-1); color: var(--text-dim); font-size: 0.9rem; }

input[type="text"], input[type="email"], input[type="password"],
input[type="date"], textarea, select {
  width: 100%;
  min-height: var(--tap);
  padding: var(--space-2) var(--space-3);
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  color: var(--text);
  font: inherit;   /* 16px floor from base.css -- stops iOS zooming on focus */
}

/* --- Tables --------------------------------------------------------------
 * Real table at width; stacked cards below. The wrapper also lets a wide
 * table scroll rather than forcing the page to scroll sideways. */
.table-wrap { overflow-x: auto; }

table { width: 100%; border-collapse: collapse; }
th, td { padding: var(--space-3); text-align: left; border-bottom: 1px solid var(--border); }
th {
  color: var(--text-dim);
  font-size: 0.78rem;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  font-weight: 600;
}

@media (max-width: 47.99rem) {
  .table--cards thead { display: none; }
  .table--cards tr {
    display: block;
    margin-bottom: var(--space-3);
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: var(--space-2);
  }
  .table--cards td { display: block; border: 0; padding: var(--space-1) var(--space-2); }
  /* Views set data-label on each cell so the column name survives the
     collapse -- without it a stacked row is a list of unlabelled values. */
  .table--cards td::before {
    content: attr(data-label);
    display: block;
    color: var(--text-dim);
    font-size: 0.72rem;
    text-transform: uppercase;
    letter-spacing: 0.07em;
  }
}

/* --- Flash, cards, panels, tags ------------------------------------------ */
.flash {
  padding: var(--space-3) var(--space-4);
  border-radius: var(--radius);
  border-left: 3px solid var(--go);
  background: var(--surface);
  margin-bottom: var(--space-4);
}
.flash--alert { border-left-color: var(--danger); }

.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: var(--space-4);
}

.panel {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: var(--space-4);
}

.tag {
  display: inline-block;
  padding: 2px var(--space-2);
  border-radius: 999px;
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-dim);
  border: 1px solid var(--border);
}
.tag--live { color: var(--go); border-color: var(--go); }
.tag--danger { color: var(--danger); border-color: var(--danger); }
```

- [ ] **Step 4: Check both themes for contrast**

Open `/login` and `/dashboard`, toggle the theme, and confirm body text, dimmed text, links and each button variant remain legible in both. The light theme's `--go` is deliberately darker than the dark theme's because the same amber fails AA on white. Record in your report what you checked and anything that looked marginal.

- [ ] **Step 5: Run both gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **658 examples** (655 + 3), 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 6: Commit**

```bash
git add public/stylesheets/components.css spec/requests/ui_contract_spec.rb
git commit -m "Add the shared component layer"
```

---

### Task 4: The play screen

**Files:**
- Modify: `app/views/game_passings/show_current_level.html.erb`, `public/stylesheets/screens.css`
- Test: `spec/requests/play_screen_spec.rb` (create)

**Interfaces:**
- Consumes: `.page--focused` (Task 2), `.btn--go`, `.countdown` (Task 3).

Read the existing template fully before editing. It renders task text, hints, the answer form, the multilingual content switcher and the captain's exit link, and it feeds `level_hint_updater.js` — which polls `/play/:id/tip` and injects hints. **Do not change that JS contract**: the element ids it writes into must survive.

- [ ] **Step 1: Confirm the ids the hint poller writes into**

`level_hint_updater.js` polls `/play/:id/tip` and injects hints into four elements by id. **These are as load-bearing as the cucumber selectors, and nothing tests them** — rename one and hints silently stop appearing mid-game, for every team, with no error anywhere. Verified at plan time (`level_hint_updater.js:96-99`):

| Id | Role |
|---|---|
| `#LevelHintsContainer` | Hints are appended here |
| `#LevelHintCountdownContainer` | Wraps the countdown |
| `#LevelHintCountdownTimerText` | The ticking number |
| `#LevelHintCountdownLoadIndicator` | «Загрузка…» while a poll is in flight |

Re-run the grep to confirm nothing has changed since, then keep all four ids exactly as they are while moving the elements into the pinned bar:

```bash
grep -nE "getElementById|\\\$\(['\"]#" public/javascripts/level_hint_updater.js
```

Report what you found and where each id ended up.

- [ ] **Step 2: Write the failing spec**

```ruby
# spec/requests/play_screen_spec.rb
require "rails_helper"

describe "the play screen", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }
  let(:player)  do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  before do
    passing
    put login_path, :params => { :email => player.email, :password => "1234" }
  end

  # The code field is the thing players came to use, and task text plus
  # accumulating hints otherwise push it further down exactly as the game gets
  # more stressful.
  it "pins the code field, the countdown and the newest hint" do
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('class="playbar"')
  end

  # A phone helpfully capitalising or autocorrecting a code is a real way to
  # lose a game. Server-side matching is already case-insensitive; this is the
  # other half.
  it "stops the keyboard mangling a code" do
    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include('autocapitalize="off"')
    expect(response.body).to include('autocorrect="off"')
    expect(response.body).to include('spellcheck="false"')
  end

  # Codes are refused while paused, so a field that still looks usable is a
  # lie. The bar shows the pause instead.
  it "replaces the bar with the pause notice when paused" do
    game.pause!

    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include(I18n.t("game_passings.paused"))
    expect(response.body).not_to include('class="playbar-form"')
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bundle exec rspec spec/requests/play_screen_spec.rb
```

Expected: FAIL — no `playbar`.

- [ ] **Step 4: Restructure the template**

Keep every existing `t()` call, every id the poller uses, the content-locale switcher and the exit link exactly as they are. Move the answer form, the countdown and the newest hint into a pinned bar at the end of the template:

```erb
<div class="playbar">
  <% if @game.paused? %>
    <p class="playbar-paused"><%= t("game_passings.paused") %></p>
  <% else %>
    <% newest = @game_passing.hints_to_show.last %>
    <% if newest %>
      <div class="playbar-hint">
        <span class="playbar-hint-label"><%= t("game_passings.show_current_level.hint_label") %></span>
        <span class="playbar-hint-text"><%= newest.translated(:text, content_locale) %></span>
      </div>
    <% end %>

    <div class="playbar-form">
      <%# form fields, submit button and countdown -- moved verbatim from
          above, including the ids level_hint_updater.js writes into. %>
    </div>
  <% end %>
</div>
```

The full hint list stays in the scrolling area above, so the clamped pinned copy never loses text.

- [ ] **Step 5: Add the styles**

```css
/* public/stylesheets/screens.css -- the play screen. */
.playbar {
  position: fixed;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 15;
  padding: var(--space-3) var(--space-4);
  /* Keeps the bar clear of the iOS home indicator. */
  padding-bottom: calc(var(--space-3) + env(safe-area-inset-bottom, 0px));
  background: var(--surface);
  border-top: 1px solid var(--border);
}

.playbar-hint {
  margin-bottom: var(--space-2);
  padding: var(--space-2) var(--space-3);
  background: var(--surface-2);
  border-left: 2px solid var(--time);
  border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
}

.playbar-hint-label {
  display: block;
  color: var(--time);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.07em;
}

/* Clamped, not truncated-and-lost: the full text is always in the list above. */
.playbar-hint-text {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.playbar-form { display: flex; gap: var(--space-2); align-items: center; }
.playbar-form input[type="text"] { flex: 1; }

.playbar-paused {
  color: var(--time);
  font-weight: 600;
  text-align: center;
}
```

- [ ] **Step 6: Verify on real viewports**

Check at 390px, 768px and 1280px, in both themes: the bar does not cover the last line of task text (that is what `.page--focused .main`'s bottom padding is for), a long hint clamps to two lines, and focusing the input on a narrow viewport does not hide the submit button behind the keyboard. Report what you saw at each width.

- [ ] **Step 7: Run the specs, then both gates**

```bash
bundle exec rspec spec/requests/play_screen_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **661 examples** (658 + 3), 0 failures, 6 pending; cucumber unchanged at 234 scenarios. Cucumber plays whole games through this template — any movement means the restructure broke a step.

- [ ] **Step 8: Commit**

```bash
git add app/views/game_passings/show_current_level.html.erb public/stylesheets/screens.css spec/requests/play_screen_spec.rb
git commit -m "Pin the code field, countdown and newest hint on the play screen"
```

---

### Task 5: Live stats and the intervention panel

**Files:**
- Modify: `app/views/game_passings/index.html.erb`, `app/views/game_passings/_intervention_controls.html.erb`, `public/stylesheets/screens.css`
- Test: `spec/requests/interventions_spec.rb` (extend)

**Interfaces:**
- Consumes: `.table--cards`, `.panel`, `.btn--danger` (Task 3).

- [ ] **Step 1: Write the failing spec**

Append inside the existing top-level `describe` in `spec/requests/interventions_spec.rb`:

```ruby
  describe "the operator layout" do
    it "keeps the stats table a real table and labels its cells for stacking" do
      passing
      sign_in(author)

      get game_stats_path(game)

      expect(response.body).to match(/<table[^>]*id="stats"/)
      # Without data-label a stacked row on a phone is a column of unlabelled
      # values -- see the .table--cards rule in components.css.
      expect(response.body).to include("data-label")
    end

    it "puts each team's actions in a panel rather than inline on the row" do
      passing
      sign_in(author)

      get game_stats_path(game)

      expect(response.body).to include("team-panel")
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/requests/interventions_spec.rb -e "operator layout"
```

Expected: FAIL — no `data-label`, no `team-panel`.

- [ ] **Step 3: Restructure the table**

Keep `<table id="stats">` and its existing columns and `t()` labels. Add `class="table--cards"`, give every `<td>` a `data-label` matching its header, and replace the inline controls column with a single disclosure per row that opens that team's panel. The panel contains the controls currently in `_intervention_controls.html.erb` — move them, do not rewrite them, and keep every route helper and label exactly as it is.

- [ ] **Step 4: Add the styles**

```css
/* screens.css -- operator. */
.team-panel {
  margin-top: var(--space-3);
  background: var(--surface-2);
}

.team-panel-actions { display: grid; gap: var(--space-2); }

/* Danger sits apart from the rest, so "return to the game" is never the
   button next to the one you meant to press. */
.team-panel-actions .btn--danger { margin-top: var(--space-3); }

.game-control {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space-3);
  align-items: center;
  margin-bottom: var(--space-4);
}
```

- [ ] **Step 5: Verify on real viewports**

At 390px the table must stack into readable cards with every value labelled; at 1280px it must remain a scannable table. Check both themes. Report what you saw.

- [ ] **Step 6: Run the specs, then both gates**

```bash
bundle exec rspec spec/requests/interventions_spec.rb spec/requests/ui_contract_spec.rb
bundle exec rspec && bundle exec cucumber
```

Expected: **663 examples** (661 + 2), 0 failures, 6 pending; cucumber unchanged. `ui_contract_spec` is the guard that `table#stats` survived.

- [ ] **Step 7: Commit**

```bash
git add app/views/game_passings public/stylesheets/screens.css spec/requests/interventions_spec.rb
git commit -m "Turn the operator screen into a readable list with a per-team panel"
```

---

### Task 6: Dashboard and game page

**Files:**
- Modify: `app/views/dashboard/*.html.erb`, `app/views/games/show.html.erb`, `app/views/games/_list.html.erb`, `public/stylesheets/screens.css`
- Test: `spec/requests/ui_contract_spec.rb` (already covers the ids)

**`#coming` and `#mygames` are named inside frozen `.feature` files. They cannot change.** Everything else on these pages is free.

- [ ] **Step 1: Confirm the guard is green before you start**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/ui_contract_spec.rb
```

Expected: PASS, 3 examples. Re-run it after every edit in this task.

- [ ] **Step 2: Lay the dashboard out on cards**

Wrap each existing section in `.card`, keeping its `id` and every `t()` call. Add a responsive grid:

```css
/* screens.css -- dashboard. */
.dash-grid {
  display: grid;
  gap: var(--space-4);
  grid-template-columns: 1fr;
}

@media (min-width: 60rem) {
  .dash-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
```

- [ ] **Step 3: Lay out the game page**

`games/show.html.erb` carries the description, start time, deadline, level list and the author's controls. Group the metadata into a `.panel`, keep the level list as a list, and give the author's actions their own row using `.btn` — with the delete link as `.btn--danger`, away from the others.

- [ ] **Step 4: Verify on real viewports and both themes**

390px, 768px, 1280px. Report anything that reflowed badly.

- [ ] **Step 5: Run both gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **663 examples**, 0 failures, 6 pending; cucumber unchanged. Many scenarios read the dashboard — if `#coming` or `#mygames` moved, cucumber fails here, not rspec.

- [ ] **Step 6: Commit**

```bash
git add app/views/dashboard app/views/games public/stylesheets/screens.css
git commit -m "Lay out the dashboard and game page on the component system"
```

---

### Task 7: The admin console

**Files:**
- Modify: `app/views/admin/dashboard/show.html.erb`, `app/views/admin/games/index.html.erb`, `app/views/admin/users/index.html.erb`, `app/views/admin/users/show.html.erb`, `app/views/admin/audit/index.html.erb`, `public/stylesheets/screens.css`

These four screens shipped as bare tables with no styling at all. They have no frozen selectors, so this is the freest task in the plan.

- [ ] **Step 1: Give the stats screen a figure grid**

Each count becomes a labelled figure rather than a table row:

```css
/* screens.css -- admin. */
.stat-grid {
  display: grid;
  gap: var(--space-3);
  grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
}

.stat {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: var(--space-4);
}

.stat-value { font-size: 1.8rem; font-weight: 650; font-variant-numeric: tabular-nums; }

.stat-label {
  color: var(--text-dim);
  font-size: 0.78rem;
  text-transform: uppercase;
  letter-spacing: 0.07em;
}
```

Keep every `t()` call — the labels are already translated in all four locales.

- [ ] **Step 2: Give the three list screens the shared table treatment**

Add `class="table--cards"` and `data-label` on every `<td>` in the games, users and audit tables, and wrap each in `.table-wrap`. Status values become `.tag`; `.tag--live` for a running game, `.tag--danger` for a withdrawn one.

- [ ] **Step 3: Separate the destructive actions**

On `admin/games/index`, the row actions include withdraw, lock and delete. Delete takes `.btn--danger`; withdraw and lock take plain `.btn`. Do not place delete adjacent to any other control.

On `admin/users/show`, the revoke button takes `.btn--danger` and grant takes `.btn--go`.

- [ ] **Step 4: Verify on real viewports and both themes**

The audit log is the widest table — check it stacks readably at 390px. Report what you saw.

- [ ] **Step 5: Run both gates**

```bash
bundle exec rspec && bundle exec cucumber
```

Expected: **663 examples**, 0 failures, 6 pending; cucumber unchanged.

- [ ] **Step 6: Commit**

```bash
git add app/views/admin public/stylesheets/screens.css
git commit -m "Lay out the admin console"
```

---

### Task 8: Sweep the remaining views and retire master.css

**Files:**
- Modify: every remaining template under `app/views/` that carries legacy markup; delete `public/stylesheets/master.css`; remove its `<link>` from both layouts

- [ ] **Step 1: Find what still depends on the old stylesheet**

```bash
grep -rn "class=\"left\"\|id=\"main\"\|id=\"header\"\|id=\"in_game\"\|<br />\|<hr />" app/views/ | grep -v layouts/
```

Every hit is legacy scaffolding. Work through them: forms get `.field`, submit buttons get `.btn--go`, destructive links get `.btn--danger`, tables get `.table-wrap` plus `.table--cards` and `data-label`.

**Change markup only.** Every `t()` call, every route helper and every id in the DOM contract table stays exactly as it is.

- [ ] **Step 2: Retire master.css**

```bash
grep -rn "master.css" app/ public/ && echo "STILL REFERENCED -- do not delete yet"
```

Once only the layout links remain, remove those two lines and `git rm public/stylesheets/master.css`.

Leave `calendar.css`, `jquery.autocomplete.css` and `thickbox.css` — they belong to vendored jQuery plugins that are still in use.

- [ ] **Step 3: Check every view renders**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/views spec/requests
```

Expected: all green. The 15 view specs render real templates and are the cheapest way to catch a partial broken by the sweep.

- [ ] **Step 4: Run everything**

```bash
bundle exec rspec && bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: **663 examples**, 0 failures, 6 pending; cucumber **234 scenarios / 2362 steps**; `All is good!`.

- [ ] **Step 5: Final pass on both themes at three widths**

Walk the app signed in as a superadmin at 390px, 768px and 1280px, in dark and light: login, dashboard, game page, play screen, stats, all four admin screens, profile, team room. Report anything still carrying legacy styling, and confirm no page scrolls horizontally.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Sweep the remaining views onto the component system and retire master.css"
```

---

## Self-Review

**Spec coverage.** Tokens and both themes (T1); `localStorage` persistence with `prefers-color-scheme` default and no database column (T1); ember palette with go/time/danger separated by treatment (T1 tokens, T3 components); no build step (T1 — plain files, no manifest); drawer navigation with a no-JS fallback and a sidebar from tablet up (T2); the play screen's pinned code field, countdown and clamped newest hint, the input hardening and the pause takeover (T4); the operator list plus per-team panel, `table#stats` preserved, cards on mobile (T5); dashboard and game page with `#coming`/`#mygames` preserved (T6); admin console (T7); the component layer that covers the remaining ~50 views, and retiring `master.css` (T3, T8); WCAG AA and three-viewport checks (T3–T8); 44px tap targets (T3).

**Deliberately absent, per the spec:** any jQuery upgrade; any behaviour, route or controller change; installation docs; manual screenshots. No task touches them.

**Placeholder scan.** No "TBD". Three steps deliberately instruct discovery rather than dictating an answer, each with a stated reason and a required report-back: T4 Step 1 (find the ids `level_hint_updater.js` depends on, because renaming one silently stops hints mid-game and no test covers it), and the viewport/contrast checks in T3–T8, which cannot be asserted in RSpec and must be looked at.

**Type consistency.** Token names defined in T1 are used unchanged in T2–T7. Component classes defined in T3 — `.btn`, `.btn--go`, `.btn--danger`, `.field`, `.table-wrap`, `.table--cards`, `.flash`, `.card`, `.panel`, `.countdown`, `.tag` — are the only ones later tasks apply. `.page`, `.page--focused`, `.topbar`, `.main`, `#drawer`, `#drawer-state`, `#drawer-toggle` come from T2 and are not redefined. `.playbar*` (T4), `.team-panel*` (T5), `.dash-grid` (T6) and `.stat*` (T7) are each introduced once, in the task that uses them.

**The risk I want reviewers watching.** `ui_contract_spec.rb` is written in Task 3 and must stay green through Tasks 4–8 — it is the only automated guard on four selectors, two of which live in files nobody may edit. A reviewer seeing it fail should treat that as the most serious possible finding in this plan: it means the refactor broke the frozen acceptance contract, and cucumber will confirm it a few minutes later.

**Running example counts.** 651 → 653 (T1) → 655 (T2) → 658 (T3) → 661 (T4) → 663 (T5) → 663 (T6) → 663 (T7) → 663 (T8). Cucumber stays at 234 scenarios / 2362 steps at every single step; any movement is a regression, never an expected cost of the redesign.
