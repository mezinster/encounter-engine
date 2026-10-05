# Superadmin Console Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Streamline the superadmin console: a section tab bar on every admin page, a per-game admin page that takes the per-row controls off the games list, a sectioned user page, and a teams list whose rare delete sits behind a disclosure.

**Architecture:** Plain Rails views and one new `show` action; no JavaScript. A tab-bar partial rendered from the application layout for every `admin/*` controller, guarded by a request spec that visits every admin page. The per-game page reuses existing actions and their existing conditions; only redirect targets change. Styling reuses the facts (`.facts`, `.fact-label`) and sheet (`.sheet-section`) classes added by PRs #189/#190, plus a small admin block in `screens.css`.

**Tech Stack:** Rails 8, ERB, RSpec request specs, Nokogiri, the `spec/layout` headless-Chrome harness, Superdesign CLI (Task 4 only).

**Spec:** `docs/superpowers/specs/2026-10-05-admin-console-controls-design.md`

## Global Constraints

- **Never edit a `.feature` file.** None touches the admin console; Cucumber totals must stay **238 scenarios (2 undefined) / 2386 steps**.
- **Offer only what the action accepts.** Every conditional control keeps its current predicate verbatim: `game.deletable?`, `game.withdrawn?`, `game.author_finished?`, `game.author_finished? && game.levels.any?`, `game.editing_locked?`, `game.started?`, `team.deletable?`, `team.members.any?`, `@user.id != @current_user.id && !@user.captain? && @user.created_games.empty?` (delete), `@user.id != @current_user.id && !@user.captain?` (anonymise), `!@user.captain?` plus a destination team (move).
- **No `data-confirm` / `data-turbo-confirm`** anywhere (inert: no Turbo, no rails-ujs). POST/DELETE controls are `button_to` or `form_with`, never `link_to … method:`.
- **CSS tokens only** — font sizes `var(--text-*)`, `@media` widths only `48rem`/`47.99rem`/`52rem`/`60rem`; `spec/stylesheets/token_discipline_spec.rb` enforces it.
- **Every new i18n key in all seven locale files** (`ru en uk ka tr be pl`); `en` must differ from `ru` (`spec/i18n_spec.rb`). User-authored values (game names, nicknames, team names) render verbatim, never through `t()`.
- **Hash rockets** (`:key => value`) in Ruby, matching the surrounding files.
- **Shell:** every command assumes `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` and the worktree root `.claude/worktrees/admin-console` as the working directory.
- **Suites:** run RSpec, Cucumber and the layout specs one after another, never concurrently (they share `db/test.sqlite3` and `tmp/storage`).
- **Refinement over spec §3.4 (flagged for the owner):** the tab bar is rendered from `app/views/layouts/application.html.erb` when `controller_path.start_with?("admin/")`, not by one line per view. Same partial, same guard spec; a new admin page cannot forget it.

## Review Focus

1. **A superadmin acting on the per-game page lands back on that page**, including after a refused action (unknown nickname in set-author, invalid run schedule). Pinned in Task 6.
2. **A withdrawn, finished, locked game shows every way back at once** — restore, unfinish and unlock are independent facts and all three must render together. Pinned in Task 5.
3. **The tab bar never appears for a non-admin page or a non-superadmin**, even though it now lives in the shared layout. Pinned in Task 1.
4. **A team with many members does not stretch its row**, yet every member is still reachable (the captain picker lists them all). Pinned in Task 10.
5. **The user page never offers delete to an author or anonymise/delete for yourself** after the regrouping. Pinned in Task 9.

## File Map

| File | Responsibility | Tasks |
|---|---|---|
| `tmp/locale_keys.rb` (scratch, gitignored) | comment-preserving add/delete of locale keys | 1 (create), 2, 5, 7, 9, 10 |
| `app/helpers/admin_helper.rb` | `admin_tab_current`, `admin_game_status_tag` | 1, 5 |
| `app/views/admin/_tabs.html.erb` | the section tab bar | 1 |
| `app/views/layouts/application.html.erb` | renders the tab bar for admin controllers | 1 |
| `public/stylesheets/screens.css` | admin tab, game page, user page, teams list rules | 1, 5, 9, 10 |
| `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` | keys added/removed | 1, 2, 5, 7, 9, 10 |
| `app/views/admin/dashboard/show.html.erb`, `users/index`, `users/show`, `audit/index` | lose footer/back links | 2 |
| `config/routes.rb` | `:show` on admin games | 5 |
| `app/controllers/admin/games_controller.rb` | `show`; redirects | 5, 6 |
| `app/controllers/games_controller.rb` | redirects of withdraw/restore/unfinish/lock/unlock | 6 |
| `app/views/admin/games/show.html.erb` (new) | per-game admin page | 5 |
| `app/views/admin/games/index.html.erb` | slim rows | 7 |
| `app/views/admin/game_entries/index.html.erb` | back link to the game page | 6 |
| `app/views/admin/users/show.html.erb` | sectioned user page | 9 |
| `app/views/admin/teams/index.html.erb` | disclosure + member truncation | 10 |
| `spec/requests/admin_tabs_spec.rb` (new) | tab bar on every admin page | 1, 5 |
| `spec/requests/admin_game_page_spec.rb` (new) | per-game page panels and conditions | 5 |
| `spec/requests/admin_user_page_spec.rb` (new) | user page sections | 9 |
| `spec/requests/admin_teams_spec.rb` | disclosure, truncation | 10 |
| existing admin specs (see Tasks 6–7) | relocated assertions | 6, 7 |
| `spec/layout/admin_console_layout_spec.rb` (new) | measured layout | 3, 8, 11 |
| `CLAUDE.md` | layout-spec list and locale count | 3, 8, 11 |

---

# PR 1 — Tab bar and dashboard

### Task 1: The admin tab bar

**Files:**
- Create: `tmp/locale_keys.rb`, `app/helpers/admin_helper.rb`, `app/views/admin/_tabs.html.erb`, `spec/requests/admin_tabs_spec.rb`, `tmp/keys_tabs.<locale>.yml` (scratch)
- Modify: `app/views/layouts/application.html.erb` (inside `<main class="main">`), `public/stylesheets/screens.css` (append), all seven `config/locales/*.yml`

**Interfaces:**
- Produces: `AdminHelper#admin_tab_current -> Symbol` (one of `:dashboard :games :users :teams :audit :settings :load_test :styleguide`); partial `admin/tabs`; CSS class `.admin-tabs`; locale keys `admin.tabs.{label,dashboard,games,users,teams,audit,settings,load_test,styleguide}`; script `tmp/locale_keys.rb` with `insert <locale> <block-file>` and `delete <locale> <dotted.key>`.

- [ ] **Step 1: Create the locale editor (scratch, not committed — `tmp/` is gitignored)**

`tmp/locale_keys.rb`:

```ruby
# One-off editor for config/locales/*.yml that keeps comments and layout
# (a YAML round-trip would drop both).
#   ruby tmp/locale_keys.rb insert ru tmp/keys_tabs.ru.yml   # block goes right after "  admin:"
#   ruby tmp/locale_keys.rb delete ru admin.dashboard.show.all_games
cmd, locale, arg = ARGV
path  = "config/locales/#{locale}.yml"
lines = File.read(path).split("\n", -1)

def block_end(lines, start, indent)
  n = start + 1
  n += 1 while n < lines.size && (lines[n].strip.empty? || lines[n].lstrip.start_with?("#") || lines[n][/\A */].size > indent)
  n
end

case cmd
when "insert"
  anchor = lines.index("  admin:") or abort "#{path}: no '  admin:' line"
  lines.insert(anchor + 1, *File.read(arg).chomp.split("\n"))
when "delete"
  idx    = lines.index("#{locale}:") or abort "#{path}: no root"
  indent = 0
  arg.split(".").each do |key|
    want  = indent + 2
    stop  = block_end(lines, idx, indent)
    found = ((idx + 1)...stop).find { |n| lines[n] =~ /\A {#{want}}#{Regexp.escape(key)}:(\s|\z)/ }
    abort "#{path}: #{arg} not found" unless found
    idx, indent = found, want
  end
  abort "#{path}: #{arg} is not a one-line leaf" if lines[idx] =~ /:\s*([|>][-+]?)?\s*\z/
  lines.delete_at(idx)
else
  abort "usage: insert <locale> <file> | delete <locale> <dotted.key>"
end
File.write(path, lines.join("\n"))
```

- [ ] **Step 2: Write the failing spec**

`spec/requests/admin_tabs_spec.rb`:

```ruby
require "rails_helper"

# The admin section tabs. Rendered from the application layout for every
# admin/* controller, so this visits every admin GET page rather than trusting
# that: a page that renders without the bar, or marks the wrong section, fails
# here. Add a row to PAGES when an admin page is added.
describe "the admin section tabs", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) { create_game(:author => superadmin) }
  let(:team) { create_team(:captain => create_user) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def tabs
    Nokogiri::HTML(response.body).at_css("nav.admin-tabs")
  end

  PAGES = {
    "dashboard"         => [ :dashboard,  -> { admin_dashboard_path } ],
    "games list"        => [ :games,      -> { admin_games_path } ],
    "game entries"      => [ :games,      -> { admin_game_entries_path(game) } ],
    "users list"        => [ :users,      -> { admin_users_path } ],
    "user page"         => [ :users,      -> { admin_user_path(superadmin) } ],
    "teams list"        => [ :teams,      -> { admin_teams_path } ],
    "team adjustment"   => [ :teams,      -> { new_admin_team_adjustment_path(:team_id => team.id) } ],
    "audit log"         => [ :audit,      -> { admin_audit_index_path } ],
    "settings"          => [ :settings,   -> { admin_settings_path } ],
    "load test"         => [ :load_test,  -> { admin_load_test_path } ],
    "styleguide"        => [ :styleguide, -> { admin_styleguide_path } ]
  }.freeze

  PAGES.each do |name, (section, path)|
    it "renders on the #{name}, marking #{section}" do
      sign_in(superadmin)
      get instance_exec(&path)

      expect(response).to have_http_status(:ok)
      expect(tabs).not_to be_nil
      expect(tabs.css("a").size).to eq(8)
      current = tabs.css("a[aria-current='page']")
      expect(current.size).to eq(1)
      expect(current.first["href"]).to eq(instance_exec(&PAGES.values.find { |s, _| s == section }.last))
    end
  end

  it "links all eight sections, in order" do
    sign_in(superadmin)
    get admin_dashboard_path

    expect(tabs.css("a").map { |a| a["href"] }).to eq([
      admin_dashboard_path, admin_games_path, admin_users_path, admin_teams_path,
      admin_audit_index_path, admin_settings_path, admin_load_test_path, admin_styleguide_path
    ])
    expect(tabs["aria-label"]).to eq("Разделы администрирования")
  end

  # The bar lives in the shared layout now, so its guard is the controller path.
  it "is absent from a non-admin page, even for a superadmin" do
    sign_in(superadmin)
    get dashboard_path

    expect(response).to have_http_status(:ok)
    expect(tabs).to be_nil
  end

  it "is absent for an ordinary user's pages" do
    sign_in(create_user)
    get dashboard_path

    expect(tabs).to be_nil
  end
end
```

Note on the `team adjustment` and `game entries` rows: `aria-current` names the *section*, so the expected href is that section's index path (`admin_teams_path`, `admin_games_path`), which is what `PAGES.values.find { |s, _| s == section }` returns — the first row for that section is its index.

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/admin_tabs_spec.rb`
Expected: FAIL — `expected: not nil, got: nil` on every page example (no `nav.admin-tabs` yet).

- [ ] **Step 4: Add the helper**

`app/helpers/admin_helper.rb`:

```ruby
module AdminHelper
  # Which admin section the current page belongs to, for the tab bar's
  # aria-current. Keyed by controller_name: entries belong to Games, team
  # adjustments to Teams.
  ADMIN_TAB_FOR_CONTROLLER = {
    "dashboard"        => :dashboard,
    "games"            => :games,
    "game_entries"     => :games,
    "users"            => :users,
    "teams"            => :teams,
    "team_adjustments" => :teams,
    "audit"            => :audit,
    "settings"         => :settings,
    "load_tests"       => :load_test,
    "styleguide"       => :styleguide
  }.freeze

  def admin_tab_current
    ADMIN_TAB_FOR_CONTROLLER.fetch(controller_name, :dashboard)
  end
end
```

- [ ] **Step 5: Add the partial**

`app/views/admin/_tabs.html.erb`:

```erb
<%# The admin console's sections. Rendered from layouts/application for every
    admin/* controller (spec/requests/admin_tabs_spec.rb visits every admin
    page). One row; on a narrow screen it scrolls inside itself rather than
    wrapping or widening the page. %>
<% tabs = [
     [ :dashboard,  admin_dashboard_path ],
     [ :games,      admin_games_path ],
     [ :users,      admin_users_path ],
     [ :teams,      admin_teams_path ],
     [ :audit,      admin_audit_index_path ],
     [ :settings,   admin_settings_path ],
     [ :load_test,  admin_load_test_path ],
     [ :styleguide, admin_styleguide_path ]
   ] %>
<% current = admin_tab_current %>
<nav class="admin-tabs" aria-label="<%= t("admin.tabs.label") %>">
  <ul>
    <% tabs.each do |key, path| %>
      <li><%= link_to t("admin.tabs.#{key}"), path, :"aria-current" => (key == current ? "page" : nil) %></li>
    <% end %>
  </ul>
</nav>
```

- [ ] **Step 6: Render it from the layout**

In `app/views/layouts/application.html.erb`, change:

```erb
      <main class="main">
        <% flash.each do |type, message| %>
```

to:

```erb
      <main class="main">
        <%# Every admin/* controller is superadmin-only (require_superadmin!),
            so the controller path is the whole guard. %>
        <%= render "admin/tabs" if controller_path.start_with?("admin/") %>
        <% flash.each do |type, message| %>
```

- [ ] **Step 7: Add the CSS** (append to `public/stylesheets/screens.css`)

```css

/* --- Admin console: the section tabs (admin/_tabs) -------------------------
 * One row always; a narrow screen scrolls the bar itself, never the page. */
.admin-tabs {
  margin-bottom: var(--space-5);
  border-bottom: 1px solid var(--border);
  overflow-x: auto;
}
.admin-tabs ul { display: flex; gap: var(--space-1); margin: 0; white-space: nowrap; }
.admin-tabs a {
  display: inline-flex;
  align-items: center;
  min-height: var(--tap);
  padding: 0 var(--space-3);
  border-bottom: 2px solid transparent;
  color: var(--text-dim);
}
.admin-tabs a:hover { color: var(--text); text-decoration: none; }
.admin-tabs a[aria-current="page"] { border-bottom-color: var(--go); color: var(--text); font-weight: 600; }
```

- [ ] **Step 8: Add the locale keys**

Create one block file per locale (4-space indent: children of `admin`), then insert each:

`tmp/keys_tabs.ru.yml`
```yaml
    tabs:
      label: "Разделы администрирования"
      dashboard: "Обзор"
      games: "Игры"
      users: "Пользователи"
      teams: "Команды"
      audit: "Журнал"
      settings: "Настройки"
      load_test: "Нагрузочный тест"
      styleguide: "Стайлгайд"
```
`tmp/keys_tabs.en.yml`
```yaml
    tabs:
      label: "Administration sections"
      dashboard: "Overview"
      games: "Games"
      users: "Users"
      teams: "Teams"
      audit: "Audit log"
      settings: "Settings"
      load_test: "Load test"
      styleguide: "Style guide"
```
`tmp/keys_tabs.uk.yml`
```yaml
    tabs:
      label: "Розділи адміністрування"
      dashboard: "Огляд"
      games: "Ігри"
      users: "Користувачі"
      teams: "Команди"
      audit: "Журнал"
      settings: "Налаштування"
      load_test: "Навантажувальний тест"
      styleguide: "Стайлгайд"
```
`tmp/keys_tabs.be.yml`
```yaml
    tabs:
      label: "Раздзелы адміністравання"
      dashboard: "Агляд"
      games: "Гульні"
      users: "Карыстальнікі"
      teams: "Каманды"
      audit: "Журнал"
      settings: "Налады"
      load_test: "Нагрузачны тэст"
      styleguide: "Стайлгайд"
```
`tmp/keys_tabs.pl.yml`
```yaml
    tabs:
      label: "Sekcje administracji"
      dashboard: "Przegląd"
      games: "Gry"
      users: "Użytkownicy"
      teams: "Drużyny"
      audit: "Dziennik"
      settings: "Ustawienia"
      load_test: "Test obciążenia"
      styleguide: "Przewodnik stylu"
```
`tmp/keys_tabs.tr.yml`
```yaml
    tabs:
      label: "Yönetim bölümleri"
      dashboard: "Genel bakış"
      games: "Oyunlar"
      users: "Kullanıcılar"
      teams: "Takımlar"
      audit: "Kayıtlar"
      settings: "Ayarlar"
      load_test: "Yük testi"
      styleguide: "Stil rehberi"
```
`tmp/keys_tabs.ka.yml`
```yaml
    tabs:
      label: "ადმინისტრირების განყოფილებები"
      dashboard: "მიმოხილვა"
      games: "თამაშები"
      users: "მომხმარებლები"
      teams: "გუნდები"
      audit: "ჟურნალი"
      settings: "პარამეტრები"
      load_test: "დატვირთვის ტესტი"
      styleguide: "სტილის გზამკვლევი"
```

Run: `for l in ru en uk ka tr be pl; do ruby tmp/locale_keys.rb insert $l tmp/keys_tabs.$l.yml; done`

- [ ] **Step 9: Run the spec and the i18n guards**

Run: `bundle exec rspec spec/requests/admin_tabs_spec.rb spec/i18n_spec.rb spec/stylesheets spec/requests/admin_nav_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 10: Mutation check, then restore**

Replace `controller_path.start_with?("admin/")` with `true` in the layout; run `bundle exec rspec spec/requests/admin_tabs_spec.rb -e "absent"`. Expected: 2 failures. Restore the line and re-run: 0 failures.

- [ ] **Step 11: Commit**

```bash
git add app/helpers/admin_helper.rb app/views/admin/_tabs.html.erb app/views/layouts/application.html.erb public/stylesheets/screens.css config/locales/*.yml spec/requests/admin_tabs_spec.rb
git commit -m "Add the admin section tabs to every admin page"
```

### Task 2: Retire the dashboard footer and sibling back links

**Files:**
- Modify: `app/views/admin/dashboard/show.html.erb:61-67`, `app/views/admin/users/index.html.erb:36`, `app/views/admin/users/show.html.erb:94`, `app/views/admin/audit/index.html.erb:60`, all seven locale files
- Test: `spec/requests/admin_tabs_spec.rb` (extend)

**Interfaces:**
- Consumes: `tmp/locale_keys.rb` (Task 1).
- Produces: nothing new. Removes keys `admin.dashboard.show.{all_games,all_teams,styleguide_link}`, `admin.users.index.back`, `admin.users.show.back`, `admin.audit.index.back`. **Keeps** `admin.dashboard.show.audit_log` (the left menu uses it), `admin.settings.title`, `admin.load_test.title`.

- [ ] **Step 1: Write the failing example** (append inside the `describe` of `spec/requests/admin_tabs_spec.rb`)

```ruby
  # The tabs replace the dashboard's footer links and the "back to the list"
  # links whose only target was a sibling admin page.
  it "leaves no duplicate navigation links on the pages it replaced them on" do
    sign_in(superadmin)

    get admin_dashboard_path
    main = Nokogiri::HTML(response.body).at_css("main")
    expect(main.css("a[href='#{admin_teams_path}']").size).to eq(1)
    expect(main.css("a[href='#{admin_styleguide_path}']").size).to eq(1)

    [ admin_users_path, admin_user_path(superadmin), admin_audit_index_path ].each do |path|
      get path
      main = Nokogiri::HTML(response.body).at_css("main")
      target = path == admin_user_path(superadmin) ? admin_users_path : admin_dashboard_path
      expect(main.css("a[href='#{target}']").size).to eq(1), "#{path} still links #{target} outside the tabs"
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/admin_tabs_spec.rb -e "duplicate"`
Expected: FAIL — `expected: 1, got: 2` for `admin_teams_path` on the dashboard.

- [ ] **Step 3: Remove the links**

- `app/views/admin/dashboard/show.html.erb`: delete the six `<p><%= link_to … %></p>` lines at the end (all_games, all_teams, audit_log, settings, load_test, styleguide_link) and the blank line between them.
- `app/views/admin/users/index.html.erb`: delete `<p><%= link_to t("admin.users.index.back"), admin_dashboard_path %></p>`.
- `app/views/admin/users/show.html.erb`: delete `<p><%= link_to t("admin.users.show.back"), admin_users_path %></p>`.
- `app/views/admin/audit/index.html.erb`: delete `<p><%= link_to t("admin.audit.index.back"), admin_dashboard_path %></p>`.

- [ ] **Step 4: Remove the now-unused keys**

```bash
for l in ru en uk ka tr be pl; do
  for k in admin.dashboard.show.all_games admin.dashboard.show.all_teams admin.dashboard.show.styleguide_link \
           admin.users.index.back admin.users.show.back admin.audit.index.back; do
    ruby tmp/locale_keys.rb delete $l $k
  done
done
grep -rn "all_teams\|styleguide_link\|users.index.back\|users.show.back\|audit.index.back\|dashboard.show.all_games" app spec   # expect no output
```

- [ ] **Step 5: Run the specs**

Run: `bundle exec rspec spec/requests/admin_tabs_spec.rb spec/requests/admin_styleguide_spec.rb spec/requests/admin_nav_spec.rb spec/i18n_spec.rb spec/requests/admin_*`
Expected: PASS. (`admin_styleguide_spec.rb:69` asserts the dashboard body contains `admin_styleguide_path`; the tab bar supplies it.)

- [ ] **Step 6: Commit**

```bash
git add app/views/admin config/locales spec/requests/admin_tabs_spec.rb
git commit -m "Drop the dashboard footer links and sibling back links the tabs replace"
```

### Task 3: Measure the tabs, update CLAUDE.md, gates, PR 1

**Files:**
- Create: `spec/layout/admin_console_layout_spec.rb`
- Modify: `CLAUDE.md` (layout-spec list; locale count)

**Interfaces:**
- Produces: `spec/layout/admin_console_layout_spec.rb` with helpers `superadmin_html(path_proc)` and `measure_admin(html, width, height, theme, script_body)` that Tasks 8 and 11 extend.

- [ ] **Step 1: Write the layout spec**

```ruby
require "rails_helper"
require_relative "../support/layout_measurement"

# The superadmin console, measured in a real browser in both themes. Excluded
# from the default run (needs chrome-headless-shell); LAYOUT_SPECS=1. A missing
# browser raises. Tasks 8 and 11 of the 2026-10-05 plan add the games list,
# the game page, the user page and the teams list to this file.
describe "the superadmin console, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def superadmin_html(path)
    put login_path, :params => { :email => superadmin.email, :password => "1234" }
    get path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def measure_admin(html, width, height, theme, body)
    measure(html, width, height, <<~JS, :tmp_name => "admin-console-measure.html")
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var vw = document.documentElement.clientWidth;
      #{body}
    JS
  end

  TABS_PROBE = <<~JS
    var links = Array.prototype.slice.call(document.querySelectorAll(".admin-tabs a"));
    var RESULT = {
      count: links.length,
      oneRow: links.every(function (a) { return Math.abs(a.getBoundingClientRect().top - links[0].getBoundingClientRect().top) < 1; }),
      shortTabs: links.filter(function (a) { return a.getBoundingClientRect().height < 43.5; }).map(function (a) { return a.textContent; }),
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "tabs, #{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure_admin(superadmin_html(admin_dashboard_path), width, height, theme, TABS_PROBE) }

        it "keeps all eight tabs on one row, full-size, without widening the page" do
          expect(m["count"]).to eq(8)
          expect(m["oneRow"]).to be(true)
          expect(m["shortTabs"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout/admin_console_layout_spec.rb`
Expected: 4 examples, 0 failures.

- [ ] **Step 3: Mutation check, then restore**

Delete `white-space: nowrap;` from `.admin-tabs ul` and change `display: flex;` to `display: flex; flex-wrap: wrap;`. Re-run. Expected: the phone examples fail on `oneRow`. Restore and re-run: 0 failures.

- [ ] **Step 4: Update CLAUDE.md**

1. In the layout-spec paragraph: "holds ten specs" → "holds eleven specs"; after the `level_sheet_layout_spec.rb` clause add: `` — and `admin_console_layout_spec.rb`, which measures the superadmin console (both themes, 390×680 and 1280×800): the section tabs on one row, full-size, never widening the page `` (Tasks 8 and 11 extend this clause); "all ten driving the same" → "all eleven driving the same"; "gets an eleventh file" → "gets a twelfth file".
2. Recount locale leaves and update the headline count and history line:

```bash
for l in ru be; do ruby -ryaml -e 'def leaves(h,p="") h.flat_map { |k,v| v.is_a?(Hash) ? leaves(v,"#{p}#{k}.") : ["#{p}#{k}"] } end; puts ARGV[0] + "=" + leaves(YAML.unsafe_load_file("config/locales/#{ARGV[0]}.yml")[ARGV[0]]).size.to_s' $l; done
```
Expected: `ru=1181 be=1182` (1178 + 9 − 6). Write the measured numbers, not these, if they differ, and add a history sentence: "The admin-console tab bar then took it from 1178 to 1181, measured at both ends: nine `admin.tabs.*` keys added, six footer and back-link keys removed, in every file."

- [ ] **Step 5: Run the gates, one after another**

```bash
bundle exec rspec                       # expect 0 failures, 6 pending
bundle exec cucumber                    # expect 238 scenarios (2 undefined, 236 passed) / 2386 steps
LAYOUT_SPECS=1 bundle exec rspec spec/layout   # expect 0 failures
```

- [ ] **Step 6: Commit, push, open PR 1** (the spec and this plan ride along in this PR)

```bash
git add spec/layout/admin_console_layout_spec.rb CLAUDE.md docs/superpowers/plans/2026-10-05-admin-console-controls.md
git commit -m "Measure the admin tabs; record the eleventh layout spec and locale count"
git push -u origin design/admin-console
gh pr create --base master --title "Admin console: section tabs on every admin page" --body "<summary, test results with real numbers>"
```

Owner approves → wait for CI → merge → fast-forward master. Continue PR 2 on a fresh branch `design/admin-game-page` from the updated master.

---

# PR 2 — Per-game admin page and slim games list

### Task 4: Superadmin game page design round (owner gate)

**Files:** none in the repo; `.superdesign/resume.json` (gitignored) gains target `admin-game-page`.

- [ ] **Step 1: Render the current games list as a reference** — write a throwaway `spec/zz_shot_spec.rb` that signs in a superadmin, creates three games (one finished with a level, one withdrawn, one running), GETs `admin_games_path`, rewrites `/stylesheets/…` hrefs to `file://` paths, writes the HTML to the scratchpad, and screenshot it with `chrome-headless-shell --window-size=1280,1100`. Delete the throwaway spec afterwards.

- [ ] **Step 2: Upload and reproduce** (Node 22: `export PATH="$HOME/.nvm/versions/node/v22.23.1/bin:$PATH"`)

```bash
npx --yes @superdesign/cli@latest upload-asset <scratchpad>/admin-games-current.png \
  --project-id d2acedc0-5ed3-40a0-87ae-15b28cce841c --purpose reference \
  --key "admin-games-current-desktop" --description "Current superadmin games list: every row's last cell holds up to six buttons and two forms"
npx --yes @superdesign/cli@latest create-design-draft --project-id d2acedc0-5ed3-40a0-87ae-15b28cce841c \
  --title "Current admin games list" --device desktop --model gemini-3.1-pro \
  -p "Create a PIXEL-PERFECT reproduction of the current superadmin games list in the reference screenshot. No design changes. Use the provided source code as the single source of truth." \
  --reference-id <canvasNode> \
  --context-file .superdesign/design-system.md public/stylesheets/tokens.css public/stylesheets/base.css public/stylesheets/layout.css public/stylesheets/components.css app/views/layouts/application.html.erb app/views/layouts/_header.html.erb app/views/layouts/_left_menu.html.erb app/views/admin/games/index.html.erb app/views/admin/_tabs.html.erb
```

- [ ] **Step 3: Branch two variations of the per-game page** — `iterate-design-draft --mode branch` with two `-p`: (A) single column of labelled `.card` panels in spec §3.1 order under a header and a `.facts` row; (B) two columns on desktop — facts and Состояние/Заявки left, Автор/Новый запуск right — with Удаление full-width below. Both prompts append the fidelity constraint ("Use ONLY the fonts, colors, spacing and component styles in the design system and tokens.css…") and the rule that every control is ≥44px and destructive actions sit apart. Same `--context-file` set as Step 2.

- [ ] **Step 4: Owner chooses.** Give the canvas and preview links; stop until the owner picks A, B, or changes. Record the choice in `.superdesign/resume.json`. **Task 5's markup is fixed by the spec; the chosen variant decides only the CSS in Task 5 Step 6** (single column vs. a two-column grid from `60rem`).

### Task 5: Per-game admin page (`Admin::GamesController#show`)

**Files:**
- Modify: `config/routes.rb` (admin `resources :games, only: [ :index ]` → `[ :index, :show ]`), `app/controllers/admin/games_controller.rb` (add `show`), `app/helpers/admin_helper.rb` (add `admin_game_status_tag`), `public/stylesheets/screens.css` (append), seven locale files, `spec/requests/admin_tabs_spec.rb` (one row)
- Create: `app/views/admin/games/show.html.erb`, `spec/requests/admin_game_page_spec.rb`, `tmp/keys_game_page.<locale>.yml`

**Interfaces:**
- Consumes: `admin/tabs` (Task 1); `.facts`, `.fact`, `.fact-label`, `.fact-value` (PR #189); `.sheet-heading` (PR #190); `game_team_counts(games) -> {:registered => {id=>n}, :playing => {id=>n}}` (`app/helpers/games_helper.rb:98`).
- Produces: route helper `admin_game_path(game)`; `AdminHelper#admin_game_status_tag(game) -> SafeBuffer`; locale keys `admin.game_page.*` listed in Step 5; CSS `.admin-game`, `.admin-panels`, `.admin-panel`.

- [ ] **Step 1: Write the failing spec**

`spec/requests/admin_game_page_spec.rb`:

```ruby
require "rails_helper"

# The per-game admin page: every per-game control the games list used to carry
# in each row, grouped into panels. Each control keeps the predicate it had on
# the list -- offering a control the action refuses is a promise the page
# cannot keep.
describe "the superadmin's game page", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def panel(key)
    doc.at_css(".admin-panel--#{key}")
  end

  def finished_with_level
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  it "refuses an anonymous visitor" do
    get admin_game_path(create_game(:author => author))
    expect(response).to redirect_to(login_path)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(author)
    get admin_game_path(create_game(:author => author))
    expect(response).to have_http_status(:unauthorized)
  end

  it "shows the game's name, author, status and facts" do
    game = create_game(:author => author, :is_draft => false, :name => "Ночной Бишкек", :max_team_number => 20)
    sign_in(superadmin)
    get admin_game_path(game)

    expect(doc.at_css("h1").text).to include("Ночной Бишкек")
    expect(doc.at_css("h1 a")["href"]).to eq(game_path(game))
    expect(doc.at_css(".admin-game-meta").text).to include(author.nickname)
    expect(doc.at_css(".admin-game-meta .tag")).not_to be_nil
    expect(doc.css(".facts .fact-label").map { |l| l.text.strip }).to eq(%w[Команды Играют Языки Забег])
    expect(doc.at_css(".facts").text).to include("0 / 20")
  end

  it "offers withdraw, lock, applications and edit for a fresh listed game -- and delete" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(superadmin)
    get admin_game_path(game)

    expect(panel("state").at_css("a[href='#{new_withdrawal_game_path(game)}']")).not_to be_nil
    expect(panel("state").to_html).to match(%r{<form[^>]*action="#{Regexp.escape(lock_game_path(game))}"})
    expect(panel("state").to_html).not_to include(restore_game_path(game))
    expect(panel("state").to_html).not_to include(unfinish_game_path(game))
    expect(panel("entries").at_css("a[href='#{admin_game_entries_path(game)}']").text).to eq("Заявки (0)")
    expect(panel("entries").at_css("a[href='#{edit_game_path(game)}']")).not_to be_nil
    expect(panel("author").at_css("form[action='#{set_author_admin_game_path(game)}']")).not_to be_nil
    expect(panel("new-run")).to be_nil
    expect(panel("danger").to_html).to include(delete_game_path(game))
  end

  # Withdrawal, author-finish and the editing lock are independent facts; a game
  # that is all three must offer every way back at once.
  it "offers restore, unfinish and unlock together on a withdrawn, finished, locked game" do
    game = finished_with_level
    game.withdraw!(:category => "other", :mode => "freeze")
    game.lock_editing!
    sign_in(superadmin)
    get admin_game_path(game)

    html = panel("state").to_html
    expect(html).to match(%r{<form[^>]*action="#{Regexp.escape(restore_game_path(game))}"})
    expect(html).to match(%r{<form[^>]*action="#{Regexp.escape(unfinish_game_path(game))}"})
    expect(html).to match(%r{<form[^>]*action="#{Regexp.escape(unlock_game_path(game))}"})
    expect(html).not_to include(new_withdrawal_game_path(game))
    expect(html).not_to include(lock_game_path(game) + '"')
  end

  it "offers a new run, with its three fields, only for a finished game with levels" do
    game = finished_with_level
    sign_in(superadmin)
    get admin_game_path(game)

    form = panel("new-run").at_css("form[action='#{open_run_admin_game_path(game)}']")
    expect(form.at_css("input[name='starts_at']")["type"]).to eq("datetime-local")
    expect(form.at_css("input[name='registration_deadline']")["type"]).to eq("datetime-local")
    expect(form.at_css("input[name='max_team_number']")["type"]).to eq("number")
  end

  it "offers no edit link once the game has started" do
    game = create_game(:author => author, :is_draft => false)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    sign_in(superadmin)
    get admin_game_path(game)

    expect(panel("entries").to_html).not_to include(edit_game_path(game))
  end

  it "offers no delete for a game that has been played" do
    played = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => played))
    sign_in(superadmin)
    get admin_game_path(played)

    expect(panel("danger")).to be_nil
    expect(response.body).not_to include(delete_game_path(played))
  end

  it "counts only the current run's pending applications" do
    game = create_game(:author => author, :is_draft => false)
    create_game_entry(:game => game, :team => create_team(:captain => create_user), :status => "new")
    sign_in(superadmin)
    get admin_game_path(game)

    expect(panel("entries").at_css("a[href='#{admin_game_entries_path(game)}']").text).to eq("Заявки (1)")
  end
end
```

Also add a row to `PAGES` in `spec/requests/admin_tabs_spec.rb`, after `"games list"`:

```ruby
    "game page"         => [ :games,      -> { admin_game_path(game) } ],
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/admin_game_page_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'admin_game_path'`.

- [ ] **Step 3: Route and action**

`config/routes.rb`, in the admin namespace:

```ruby
    resources :games, only: [ :index, :show ] do
```

`app/controllers/admin/games_controller.rb`, after `index`:

```ruby
  # Every per-game control the list used to carry in each row, grouped into
  # panels. One game, so the list's batching concerns do not arise: the counts
  # below are single queries.
  def show
    @game = Game.includes(:author, :runs).find(params[:id])
    @pending_entry_count = GameEntry.with_status("new")
                                    .where(:game_run_id => @game.current_run.id)
                                    .count
  end
```

- [ ] **Step 4: Status-tag helper** (add to `AdminHelper`; Task 7 makes the list use it too)

```ruby
  # The console's status tag for a game -- one mapping for the list and the
  # game page.
  def admin_game_status_tag(game)
    case game.status
    when :withdrawn then content_tag(:span, t("admin.games.index.withdrawn"), :class => "tag tag--danger")
    when :draft     then content_tag(:span, t("admin.games.index.draft"),     :class => "tag")
    when :finished  then content_tag(:span, t("admin.games.index.finished"),  :class => "tag")
    when :available then content_tag(:span, t("admin.games.index.available"), :class => "tag")
    when :running   then content_tag(:span, t("admin.games.index.running"),   :class => "tag tag--live")
    else                 content_tag(:span, t("admin.games.index.scheduled"), :class => "tag")
    end
  end
```

- [ ] **Step 5: The view and its keys**

`app/views/admin/games/show.html.erb`:

```erb
<% page_title t("titles.admin") %>
<%# Every per-game control the games list used to carry in each row. Each
    panel, and each control in it, renders only when its action would accept --
    the same predicates the list used. Actions here redirect back to this page. %>
<% counts = game_team_counts([@game]) %>
<% playing = counts[:playing].fetch(@game.id, 0) %>
<div class="admin-game">
  <h1><%= link_to @game.name, game_path(@game) %></h1>
  <p class="admin-game-meta">
    <%= t("admin.game_page.author") %>: <strong><%= @game.author&.nickname %></strong>
    <%= admin_game_status_tag(@game) %>
    <% if @game.editing_locked? %><span class="tag"><%= t("admin.games.index.locked") %></span><% end %>
  </p>

  <dl class="facts">
    <div class="fact">
      <dt class="fact-label"><%= t("admin.game_page.facts_teams") %></dt>
      <dd class="fact-value"><%= counts[:registered].fetch(@game.id, 0) %> / <%= @game.max_team_number %></dd>
    </div>
    <div class="fact">
      <dt class="fact-label"><%= t("admin.game_page.facts_playing") %></dt>
      <dd class="fact-value"><%= playing %></dd>
    </div>
    <div class="fact">
      <dt class="fact-label"><%= t("admin.game_page.facts_locales") %></dt>
      <dd class="fact-value"><%= @game.available_locale_list.join(", ") %></dd>
    </div>
    <div class="fact">
      <dt class="fact-label"><%= t("admin.game_page.facts_run") %></dt>
      <dd class="fact-value"><%= t("admin.game_page.run_ordinal", :ordinal => @game.current_run.ordinal) %></dd>
    </div>
  </dl>

  <div class="admin-panels">
    <section class="card admin-panel admin-panel--state">
      <h2 class="fact-label"><%= t("admin.game_page.state") %></h2>
      <div class="game-control">
        <% if @game.withdrawn? %>
          <%= button_to t("admin.games.index.restore"), restore_game_path(@game), :method => :post, :class => "btn" %>
        <% else %>
          <%= link_to t("admin.games.index.withdraw"), new_withdrawal_game_path(@game), :class => "btn" %>
        <% end %>
        <%# Independent of withdraw/restore: a withdrawn-and-finished game
            legitimately offers both ways back. %>
        <% if @game.author_finished? %>
          <%= button_to t("admin.games.index.unfinish"), unfinish_game_path(@game), :method => :post, :class => "btn" %>
        <% end %>
        <% if @game.editing_locked? %>
          <%= button_to t("admin.games.index.unlock"), unlock_game_path(@game), :method => :post, :class => "btn" %>
        <% else %>
          <%= button_to t("admin.games.index.lock"), lock_game_path(@game), :method => :post, :class => "btn" %>
        <% end %>
      </div>
    </section>

    <section class="card admin-panel admin-panel--entries">
      <h2 class="fact-label"><%= t("admin.game_page.entries") %></h2>
      <div class="game-control">
        <%= link_to t("admin.games.index.entries_link", :count => @pending_entry_count),
                    admin_game_entries_path(@game), :class => "btn" %>
        <%= link_to t("admin.games.index.edit"), edit_game_path(@game), :class => "btn" unless @game.started? %>
      </div>
    </section>

    <%# A text field rather than a select: the target is any user on the
        instance, so a dropdown would list the entire membership. %>
    <section class="card admin-panel admin-panel--author">
      <h2 class="fact-label"><%= t("admin.game_page.author") %></h2>
      <%= form_with url: set_author_admin_game_path(@game), method: :post, :class => "admin-inline-form" do %>
        <div class="field">
          <%= label_tag :nickname, t("admin.games.index.author_nickname") %>
          <%= text_field_tag :nickname, nil, :autocomplete => "off" %>
        </div>
        <%= submit_tag t("admin.games.index.set_author"), :class => "btn" %>
      <% end %>
    </section>

    <%# Only for a finished game with levels: Admin::GamesController#open_run
        refuses every other game. Native datetime-local inputs submit
        YYYY-MM-DDTHH:MM, which the action accepts unchanged. %>
    <% if @game.author_finished? && @game.levels.any? %>
      <section class="card admin-panel admin-panel--new-run">
        <h2 class="fact-label"><%= t("admin.game_page.new_run") %></h2>
        <%= form_with url: open_run_admin_game_path(@game), method: :post, :class => "admin-inline-form" do %>
          <div class="field">
            <%= label_tag :starts_at, t("admin.games.index.run_starts_at") %>
            <%= datetime_local_field_tag :starts_at, nil, :required => true %>
          </div>
          <div class="field">
            <%= label_tag :registration_deadline, t("admin.games.index.run_deadline") %>
            <%= datetime_local_field_tag :registration_deadline, nil %>
          </div>
          <div class="field">
            <%= label_tag :max_team_number, t("admin.games.index.run_max_teams") %>
            <%= number_field_tag :max_team_number, @game.max_team_number, :min => 1, :max => 9999 %>
          </div>
          <%= submit_tag t("admin.games.index.open_run"), :class => "btn" %>
        <% end %>
      </section>
    <% end %>
  </div>

  <% if @game.deletable? %>
    <section class="admin-panel admin-panel--danger danger-row">
      <h2 class="fact-label"><%= t("admin.game_page.danger") %></h2>
      <%= button_to t("admin.games.index.delete"), delete_game_path(@game), :method => :delete, :class => "btn btn--danger" %>
    </section>
  <% end %>
</div>
```

Keys — `tmp/keys_game_page.<locale>.yml`, inserted with `ruby tmp/locale_keys.rb insert <l> tmp/keys_game_page.<l>.yml`:

```yaml
# ru
    game_page:
      manage: "Управление →"
      author: "Автор"
      facts_teams: "Команды"
      facts_playing: "Играют"
      facts_locales: "Языки"
      facts_run: "Забег"
      run_ordinal: "№ %{ordinal}"
      state: "Состояние"
      entries: "Заявки"
      new_run: "Новый запуск"
      danger: "Удаление"
      back_to_game: "К управлению игрой"
```
```yaml
# en
    game_page:
      manage: "Manage →"
      author: "Author"
      facts_teams: "Teams"
      facts_playing: "Playing"
      facts_locales: "Languages"
      facts_run: "Run"
      run_ordinal: "No. %{ordinal}"
      state: "Status"
      entries: "Applications"
      new_run: "New run"
      danger: "Deletion"
      back_to_game: "Back to game management"
```
```yaml
# uk
    game_page:
      manage: "Керування →"
      author: "Автор"
      facts_teams: "Команди"
      facts_playing: "Грають"
      facts_locales: "Мови"
      facts_run: "Забіг"
      run_ordinal: "№ %{ordinal}"
      state: "Стан"
      entries: "Заявки"
      new_run: "Новий запуск"
      danger: "Видалення"
      back_to_game: "До керування грою"
```
```yaml
# be
    game_page:
      manage: "Кіраванне →"
      author: "Аўтар"
      facts_teams: "Каманды"
      facts_playing: "Гуляюць"
      facts_locales: "Мовы"
      facts_run: "Забег"
      run_ordinal: "№ %{ordinal}"
      state: "Стан"
      entries: "Заяўкі"
      new_run: "Новы запуск"
      danger: "Выдаленне"
      back_to_game: "Да кіравання гульнёй"
```
```yaml
# pl
    game_page:
      manage: "Zarządzaj →"
      author: "Autor"
      facts_teams: "Drużyny"
      facts_playing: "Grają"
      facts_locales: "Języki"
      facts_run: "Edycja"
      run_ordinal: "nr %{ordinal}"
      state: "Stan"
      entries: "Zgłoszenia"
      new_run: "Nowa edycja"
      danger: "Usuwanie"
      back_to_game: "Wróć do zarządzania grą"
```
```yaml
# tr
    game_page:
      manage: "Yönet →"
      author: "Yazar"
      facts_teams: "Takımlar"
      facts_playing: "Oynayan"
      facts_locales: "Diller"
      facts_run: "Tur"
      run_ordinal: "%{ordinal}. tur"
      state: "Durum"
      entries: "Başvurular"
      new_run: "Yeni tur"
      danger: "Silme"
      back_to_game: "Oyun yönetimine dön"
```
```yaml
# ka
    game_page:
      manage: "მართვა →"
      author: "ავტორი"
      facts_teams: "გუნდები"
      facts_playing: "თამაშობს"
      facts_locales: "ენები"
      facts_run: "გაშვება"
      run_ordinal: "№ %{ordinal}"
      state: "მდგომარეობა"
      entries: "განაცხადები"
      new_run: "ახალი გაშვება"
      danger: "წაშლა"
      back_to_game: "თამაშის მართვაზე დაბრუნება"
```

(Write each block to its own file without the `# locale` comment line.)

- [ ] **Step 6: CSS** (append to `screens.css`; the two-column rule is used only if the owner picked variant B in Task 4)

```css

/* --- Admin console: the per-game page (admin/games/show) ------------------- */
.admin-game-meta { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2); color: var(--text-dim); }
.admin-game .facts { margin: var(--space-4) 0 var(--space-5); }
.admin-panels { display: grid; gap: var(--space-4); }
.admin-panel .fact-label { margin-bottom: var(--space-3); }
.admin-panel form { margin: 0; }
.admin-inline-form { display: flex; flex-wrap: wrap; align-items: flex-end; gap: var(--space-3); }
.admin-inline-form .field { margin: 0; }
.admin-panel--danger { margin-top: var(--space-5); padding-top: var(--space-4); border-top: 1px solid var(--border); }
/* Variant B only: */
@media (min-width: 60rem) {
  .admin-panels { grid-template-columns: 1fr 1fr; }
}
```

- [ ] **Step 7: Run the specs**

Run: `bundle exec rspec spec/requests/admin_game_page_spec.rb spec/requests/admin_tabs_spec.rb spec/i18n_spec.rb spec/stylesheets`
Expected: PASS.

- [ ] **Step 8: Mutation check, then restore** — change `<% if @game.deletable? %>` to `<% if true %>`; `bundle exec rspec spec/requests/admin_game_page_spec.rb -e "played"` must fail. Restore; re-run passes.

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/controllers/admin/games_controller.rb app/helpers/admin_helper.rb app/views/admin/games/show.html.erb public/stylesheets/screens.css config/locales/*.yml spec/requests/admin_game_page_spec.rb spec/requests/admin_tabs_spec.rb
git commit -m "Add the superadmin's per-game page"
```

### Task 6: Actions return to the game page

**Files:**
- Modify: `app/controllers/games_controller.rb` (`withdraw` line ~182, `restore` ~193, `unfinish` ~204, `lock` ~210, `unlock` ~216), `app/controllers/admin/games_controller.rb` (`set_author`, `open_run` — every `redirect_to admin_games_path`), `app/views/admin/game_entries/index.html.erb:65`, seven locale files (delete `admin.entries.back`)
- Test: `spec/requests/withdrawal_spec.rb:86,90,107,111`, `spec/requests/unfinish_spec.rb:29`, `spec/requests/admin_game_authorship_spec.rb:22`, `spec/requests/admin_open_run_spec.rb:33`, new examples in `spec/requests/admin_game_page_spec.rb`

**Interfaces:**
- Consumes: `admin_game_path(game)` (Task 5), key `admin.game_page.back_to_game` (Task 5).

- [ ] **Step 1: Update the redirect expectations and add the refusal cases**

In each listed line, replace `redirect_to(admin_games_path)` with `redirect_to(admin_game_path(game))` (use the spec's own game variable at that line — `game` in all five files; check each). Then append to `spec/requests/admin_game_page_spec.rb`:

```ruby
  describe "after acting" do
    it "returns to this page when set-author names nobody" do
      game = create_game(:author => author)
      sign_in(superadmin)
      post set_author_admin_game_path(game), :params => { :nickname => "nobody-#{SecureRandom.hex(4)}" }

      expect(response).to redirect_to(admin_game_path(game))
      expect(flash[:alert]).to be_present
    end

    it "returns to this page when a run's schedule is invalid" do
      game = finished_with_level
      sign_in(superadmin)
      post open_run_admin_game_path(game), :params => { :starts_at => "", :max_team_number => 5 }

      expect(response).to redirect_to(admin_game_path(game))
      expect(flash[:alert]).to be_present
    end

    it "returns to this page after lock and unlock" do
      game = create_game(:author => author, :is_draft => false)
      sign_in(superadmin)
      post lock_game_path(game)
      expect(response).to redirect_to(admin_game_path(game))
      post unlock_game_path(game)
      expect(response).to redirect_to(admin_game_path(game))
    end

    it "links the entries screen back to this page" do
      game = create_game(:author => author)
      sign_in(superadmin)
      get admin_game_entries_path(game)

      link = Nokogiri::HTML(response.body).at_css("main a[href='#{admin_game_path(game)}']")
      expect(link.text).to eq("К управлению игрой")
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/requests/withdrawal_spec.rb spec/requests/unfinish_spec.rb spec/requests/admin_game_authorship_spec.rb spec/requests/admin_open_run_spec.rb spec/requests/admin_game_page_spec.rb`
Expected: FAIL — `Expected response to be a redirect to <…/admin/games/N> but was a redirect to <…/admin/games>`.

- [ ] **Step 3: Change the redirects**

- `app/controllers/games_controller.rb`: in `withdraw`, `restore`, `unfinish`, `lock`, `unlock`, replace `redirect_to admin_games_path,` with `redirect_to admin_game_path(@game),` (the `:notice` stays).
- `app/controllers/admin/games_controller.rb`: replace every `redirect_to admin_games_path` with `redirect_to admin_game_path(game)` (six occurrences: one in `set_author`'s refusal, one on its success, three in `open_run`, one in its `rescue`).
- `app/views/admin/game_entries/index.html.erb`: replace `<p><%= link_to t("admin.entries.back"), admin_games_path %></p>` with `<p><%= link_to t("admin.game_page.back_to_game"), admin_game_path(@game) %></p>`.
- Keys: `for l in ru en uk ka tr be pl; do ruby tmp/locale_keys.rb delete $l admin.entries.back; done`

- [ ] **Step 4: Run them again**

Same command as Step 2. Expected: PASS. Then `grep -n "admin_games_path" app/controllers` — expected: no output.

- [ ] **Step 5: Commit**

```bash
git add app/controllers app/views/admin/game_entries/index.html.erb config/locales spec/requests
git commit -m "Return per-game admin actions to the game's admin page"
```

### Task 7: Slim the games list

**Files:**
- Modify: `app/views/admin/games/index.html.erb` (the status cell and the whole last `<td>`)
- Test: `spec/requests/admin_console_spec.rb:66-104`, `spec/requests/admin_game_authorship_spec.rb:113-123`, `spec/requests/admin_open_run_spec.rb:144-153`, `spec/requests/admin_open_run_form_spec.rb:26-31`, new examples in `spec/requests/admin_game_page_spec.rb`

**Interfaces:**
- Consumes: `admin_game_status_tag` (Task 5), `admin.game_page.manage` (Task 5).

- [ ] **Step 1: Move the per-game assertions to the game page, and pin the slim row**

- `admin_console_spec.rb` "offers withdrawal but not deletion…" and "offers revival, as a POST form…": change `get admin_games_path` to `get admin_game_path(played)` / two GETs (`admin_game_path(finished)` asserting the form; `admin_game_path(running)` asserting `not_to include(unfinish_game_path(running))`).
- `admin_game_authorship_spec.rb` "offers the form on the console": `get admin_game_path(listed)`; rename to "offers the form on the game's admin page".
- `admin_open_run_spec.rb` "offers the form on the console": same change.
- `admin_open_run_form_spec.rb` `form_html`: `get admin_game_path(listed)`.

Append to `spec/requests/admin_game_page_spec.rb`:

```ruby
  describe "the games list" do
    it "gives each row exactly two actions: applications and manage" do
      game = finished_with_level
      sign_in(superadmin)
      get admin_games_path

      row = doc.css("tbody tr").find { |tr| tr.at_css("a[href='#{game_path(game)}']") }
      actions = row.css("td:last-child a.btn, td:last-child button, td:last-child input[type=submit]")
      expect(actions.map { |a| a["href"] }).to eq([ admin_game_entries_path(game), admin_game_path(game) ])
      expect(row.css("form")).to be_empty
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/admin_game_page_spec.rb -e "games list"`
Expected: FAIL — more than two actions, forms present.

- [ ] **Step 3: Rewrite the row**

In `app/views/admin/games/index.html.erb`:
1. Replace the whole status `case … end` block in the status cell with `<%= admin_game_status_tag(game) %>` (keep the `editing_locked?` suffix line after it).
2. Replace the entire last `<td> … </td>` (from `<td>` before the first `<div class="game-control">` through the closing `</td>` before `</tr>`) with:

```erb
      <td>
        <%# Two actions only: the frequent one, and the door to every other
            per-game control (admin/games/show). The count comes from
            @pending_entry_counts -- one grouped query for the whole page. %>
        <div class="game-control">
          <%= link_to t("admin.games.index.entries_link",
                        :count => @pending_entry_counts.fetch(game.current_run.id, 0)),
                      admin_game_entries_path(game), :class => "btn" %>
          <%= link_to t("admin.game_page.manage"), admin_game_path(game), :class => "btn" %>
        </div>
      </td>
```

3. Keep the controller's `index` preloads as they are: `deletable?` is no longer called per row, but removing preloads is out of scope; the N+1 guard in `admin_console_spec.rb` keeps passing either way.

- [ ] **Step 4: Run the admin specs**

Run: `bundle exec rspec spec/requests/admin_* spec/requests/withdrawal_spec.rb spec/requests/unfinish_spec.rb spec/requests/empty_states_a_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/views/admin/games/index.html.erb spec/requests
git commit -m "Slim the admin games list to two actions per row"
```

### Task 8: Measure the game page and the list, gates, PR 2

**Files:** Modify `spec/layout/admin_console_layout_spec.rb`, `CLAUDE.md`.

- [ ] **Step 1: Add examples** inside the outer `describe`, after the tabs loop:

```ruby
  GAME_PAGE_PROBE = <<~JS
    var controls = Array.prototype.slice.call(document.querySelectorAll(".admin-game .btn, .admin-game input:not([type=hidden]), .admin-game button"));
    var RESULT = {
      count: controls.length,
      short: controls.filter(function (el) { return el.getBoundingClientRect().height < 43.5; }).map(function (el) { return el.outerHTML.slice(0, 80); }),
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  LIST_PROBE = <<~JS
    var rows = Array.prototype.slice.call(document.querySelectorAll("tbody tr"));
    var RESULT = {
      rows: rows.length,
      actionCounts: rows.map(function (tr) { return tr.querySelectorAll("td:last-child .btn").length; }),
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  def finished_game
    g = create_game(:author => superadmin, :is_draft => false, :name => "Оченьдлинноеназваниеигрыбезпробелов" * 2)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "game page and list, #{theme} theme at #{width}x#{height} -- #{name}" do
        it "makes every control on the game page full-size, without sideways scroll" do
          m = measure_admin(superadmin_html(admin_game_path(finished_game)), width, height, theme, GAME_PAGE_PROBE)
          expect(m["count"]).to be >= 9
          expect(m["short"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end

        it "gives each list row exactly two actions" do
          3.times { finished_game }
          m = measure_admin(superadmin_html(admin_games_path), width, height, theme, LIST_PROBE)
          expect(m["rows"]).to eq(3)
          expect(m["actionCounts"]).to eq([ 2, 2, 2 ])
          expect(m["hOverflow"]).to be <= 0
        end
      end
    end
  end
```

- [ ] **Step 2: Run it** — `LAYOUT_SPECS=1 bundle exec rspec spec/layout/admin_console_layout_spec.rb` → 12 examples, 0 failures. If a control is short, fix the CSS (inputs inherit `min-height` from `components.css`; check `.admin-inline-form`), never the threshold.

- [ ] **Step 3: CLAUDE.md** — extend the `admin_console_layout_spec.rb` clause: "…the section tabs on one row, full-size, never widening the page; every control on the per-game page at least 44px; exactly two actions per games-list row". Recount locales (expected `ru=1192 be=1193`: 1181 + 12 − 1) and add the history sentence with measured numbers.

- [ ] **Step 4: Gates** — full RSpec, Cucumber (238/2386), all layout specs, one after another.

- [ ] **Step 5: Commit, push, open PR 2**; owner approves → CI green → merge. Continue PR 3 on `design/admin-people` from the updated master.

---

# PR 3 — User page and teams list

### Task 9: Sectioned user page

**Files:**
- Modify: `app/views/admin/users/show.html.erb` (whole file), `public/stylesheets/screens.css` (append), seven locale files
- Create: `spec/requests/admin_user_page_spec.rb`, `tmp/keys_user_page.<locale>.yml`

**Interfaces:**
- Consumes: `.facts` family, `.sheet-section`, `.danger-row`, `.tag`.
- Produces: keys `admin.user_page.{profile,roles,team,account,superadmin_hint,operator_hint,anonymise_hint,delete_hint}`; CSS `.admin-user`, `.role-row`.

- [ ] **Step 1: Write the failing spec**

`spec/requests/admin_user_page_spec.rb`:

```ruby
require "rails_helper"

# The superadmin's user page, regrouped into sections: profile, roles, team,
# account. Every control keeps the condition Admin::UsersController enforces.
describe "the superadmin's user page", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def section(key)
    doc.at_css(".admin-user .sheet-section--#{key}")
  end

  it "groups the page into profile, roles, team and account, in that order" do
    target = create_user
    create_team(:captain => create_user).members << target
    sign_in(superadmin)
    get admin_user_path(target)

    expect(doc.css(".admin-user .sheet-section").map { |s| s["class"][/sheet-section--(\w+)/, 1] })
      .to eq(%w[profile roles team account])
    expect(section("profile").css(".fact-label").map { |l| l.text.strip }).to include("E-mail", "Команда", "Регистрация")
  end

  it "shows role tags beside the name" do
    target = create_user
    target.update!(:is_superadmin => true, :is_operator => true)
    sign_in(superadmin)
    get admin_user_path(target)

    expect(doc.css(".admin-user h1 + .admin-user-roles .tag").map(&:text)).to eq(%w[суперадмин оператор])
  end

  it "grants with the filled button and revokes with a plain one" do
    target = create_user
    target.update!(:is_operator => true)
    sign_in(superadmin)
    get admin_user_path(target)

    grant  = section("roles").at_css("form[action='#{grant_admin_user_path(target)}'] button")
    revoke = section("roles").at_css("form[action='#{revoke_operator_admin_user_path(target)}'] button")
    expect(grant["class"]).to include("btn--go")
    expect(revoke["class"].split).to eq(%w[btn])
    expect(section("roles").css(".role-hint").size).to eq(2)
  end

  it "offers anonymise and delete, with their explanations, for a plain user" do
    target = create_user
    sign_in(superadmin)
    get admin_user_path(target)

    account = section("account")
    expect(account.at_css("form[action='#{anonymise_admin_user_path(target)}']")).not_to be_nil
    expect(account.at_css("form[action='#{destroy_admin_user_path(target)}'] button")["class"]).to include("btn--danger")
    expect(account.css(".role-hint").size).to eq(2)
  end

  it "never offers anonymise or delete on your own page" do
    sign_in(superadmin)
    get admin_user_path(superadmin)

    expect(response.body).not_to include(anonymise_admin_user_path(superadmin))
    expect(response.body).not_to include(destroy_admin_user_path(superadmin))
    expect(section("account")).to be_nil
  end

  it "offers an author anonymise but not delete" do
    target = create_user
    create_game(:author => target)
    sign_in(superadmin)
    get admin_user_path(target)

    expect(section("account").to_html).to include(anonymise_admin_user_path(target))
    expect(section("account").to_html).not_to include(destroy_admin_user_path(target))
  end

  it "offers a captain neither the move nor the account actions" do
    captain = create_user
    create_team(:captain => captain)
    create_team(:captain => create_user)
    sign_in(superadmin)
    get admin_user_path(captain)

    expect(section("team")).to be_nil
    expect(section("account")).to be_nil
  end
end
```

- [ ] **Step 2: Run to verify it fails** — `bundle exec rspec spec/requests/admin_user_page_spec.rb` → FAIL (`.admin-user` absent).

- [ ] **Step 3: Replace `app/views/admin/users/show.html.erb`**

```erb
<% page_title t("titles.admin") %>
<%# Sectioned like the level page: profile, roles, team, account. Every
    control keeps the condition Admin::UsersController enforces -- see the
    comments below, carried over from the flat version of this page. %>
<% may_move    = !@user.captain? && Team.where.not(:id => @user.team_id).exists? %>
<% may_anon    = @user.id != @current_user.id && !@user.captain? %>
<% may_delete  = may_anon && @user.created_games.empty? %>
<div class="admin-user">
  <h1><%= @user.nickname %></h1>
  <p class="admin-user-roles">
    <% if @user.superadmin? %><span class="tag"><%= t("admin.users.index.superadmin") %></span><% end %>
    <% if @user.operator? %><span class="tag"><%= t("admin.users.index.operator") %></span><% end %>
  </p>

  <section class="sheet-section sheet-section--profile">
    <h2 class="fact-label"><%= t("admin.user_page.profile") %></h2>
    <dl class="facts">
      <% [ [ :email, @user.email ], [ :phone, @user.phone_number ], [ :instagram, @user.instagram ],
           [ :telegram, @user.telegram_id ], [ :messengers, messenger_list_for(@user) ],
           [ :date_of_birth, @user.date_of_birth ], [ :team, @user.team&.name ], [ :locale, @user.locale ],
           [ :signed_up, l(@user.created_at, :format => :long) ] ].each do |key, value| %>
        <div class="fact">
          <dt class="fact-label"><%= t("admin.users.show.#{key}") %></dt>
          <dd class="fact-value"><%= value %></dd>
        </div>
      <% end %>
    </dl>
    <%# There is no team history: users.team_id is one column. Participation
        runs through the team, so "games this person played" is deliberately
        not attempted. %>
    <h3 class="fact-label"><%= t("admin.users.show.authored_games") %></h3>
    <ul class="game-list">
      <% @user.created_games.each do |game| %>
        <li><%= link_to game.name, game_path(game) %></li>
      <% end %>
    </ul>
  </section>

  <section class="sheet-section sheet-section--roles">
    <h2 class="fact-label"><%= t("admin.user_page.roles") %></h2>
    <div class="role-row">
      <% if @user.superadmin? %>
        <%= button_to t("admin.users.show.revoke"), revoke_admin_user_path(@user), :method => :post, :class => "btn" %>
      <% else %>
        <%= button_to t("admin.users.show.grant"), grant_admin_user_path(@user), :method => :post, :class => "btn btn--go" %>
      <% end %>
      <p class="role-hint"><%= t("admin.user_page.superadmin_hint") %></p>
    </div>
    <div class="role-row">
      <% if @user.operator? %>
        <%= button_to t("admin.users.show.revoke_operator"), revoke_operator_admin_user_path(@user), :method => :post, :class => "btn" %>
      <% else %>
        <%= button_to t("admin.users.show.grant_operator"), grant_operator_admin_user_path(@user), :method => :post, :class => "btn btn--go" %>
      <% end %>
      <p class="role-hint"><%= t("admin.user_page.operator_hint") %></p>
    </div>
  </section>

  <%# The move action refuses a captain -- the remedy is captaincy
      reassignment on the admin teams screen. A form: a select cannot ride
      button_to, and this app has no rails-ujs. %>
  <% if may_move %>
    <section class="sheet-section sheet-section--team">
      <h2 class="fact-label"><%= t("admin.user_page.team") %></h2>
      <%= form_with url: move_admin_user_path(@user), method: :post, :class => "admin-inline-form" do %>
        <%= select_tag :team_id, options_from_collection_for_select(Team.where.not(:id => @user.team_id).order(:name), :id, :name) %>
        <%= submit_tag t("admin.users.show.move"), :class => "btn" %>
      <% end %>
    </section>
  <% end %>

  <%# Offered only where #anonymise / #destroy would accept: not yourself, not
      a captain; delete additionally not an author (anonymise instead -- their
      games survive with a scrubbed author). No confirmation attribute: no
      Turbo, no rails-ujs, so it would be inert; the guards are the protection. %>
  <% if may_anon %>
    <section class="sheet-section sheet-section--account danger-row">
      <h2 class="fact-label"><%= t("admin.user_page.account") %></h2>
      <div class="role-row">
        <%= button_to t("admin.users.show.anonymise"), anonymise_admin_user_path(@user), :method => :post, :class => "btn" %>
        <p class="role-hint"><%= t("admin.user_page.anonymise_hint") %></p>
      </div>
      <% if may_delete %>
        <div class="role-row">
          <%= button_to t("admin.users.show.delete"), destroy_admin_user_path(@user), :method => :delete, :class => "btn btn--danger" %>
          <p class="role-hint"><%= t("admin.user_page.delete_hint") %></p>
        </div>
      <% end %>
    </section>
  <% end %>
</div>
```

Check before running: `admin.users.index.superadmin`/`operator` render «суперадмин»/«оператор» in ru (adjust the spec's expected tag text to the real values if they differ — read them with `ruby -ryaml -e 'p YAML.load_file("config/locales/ru.yml")["ru"]["admin"]["users"]["index"].values_at("superadmin","operator")'`).

- [ ] **Step 4: Keys** — `tmp/keys_user_page.<l>.yml`, inserted like Task 1:

```yaml
# ru
    user_page:
      profile: "Профиль"
      roles: "Роли"
      team: "Команда"
      account: "Аккаунт"
      superadmin_hint: "Полный доступ к консоли администрирования, включая роли других пользователей."
      operator_hint: "Ведёт игры по пропускам: пропуска, коды доступа, ход игры. Без доступа к этой консоли."
      anonymise_hint: "Стирает личные данные, отвязывает от команды и снимает роли; созданные игры остаются."
      delete_hint: "Удаляет аккаунт целиком. Необратимо."
```
```yaml
# en
    user_page:
      profile: "Profile"
      roles: "Roles"
      team: "Team"
      account: "Account"
      superadmin_hint: "Full access to the administration console, including other users' roles."
      operator_hint: "Runs pass-only games: passes, access codes, gameplay. No access to this console."
      anonymise_hint: "Erases personal data, detaches them from their team and removes their roles; games they created remain."
      delete_hint: "Deletes the account entirely. Cannot be undone."
```
```yaml
# uk
    user_page:
      profile: "Профіль"
      roles: "Ролі"
      team: "Команда"
      account: "Обліковий запис"
      superadmin_hint: "Повний доступ до консолі адміністрування, зокрема до ролей інших користувачів."
      operator_hint: "Веде ігри за перепустками: перепустки, коди доступу, перебіг гри. Без доступу до цієї консолі."
      anonymise_hint: "Стирає особисті дані, відв'язує від команди й знімає ролі; створені ігри лишаються."
      delete_hint: "Видаляє обліковий запис повністю. Незворотно."
```
```yaml
# be
    user_page:
      profile: "Профіль"
      roles: "Ролі"
      team: "Каманда"
      account: "Уліковы запіс"
      superadmin_hint: "Поўны доступ да кансолі адміністравання, у тым ліку да роляў іншых карыстальнікаў."
      operator_hint: "Вядзе гульні па пропусках: пропускі, коды доступу, ход гульні. Без доступу да гэтай кансолі."
      anonymise_hint: "Сцірае асабістыя даныя, адвязвае ад каманды і здымае ролі; створаныя гульні застаюцца."
      delete_hint: "Выдаляе ўліковы запіс цалкам. Незваротна."
```
```yaml
# pl
    user_page:
      profile: "Profil"
      roles: "Role"
      team: "Drużyna"
      account: "Konto"
      superadmin_hint: "Pełny dostęp do konsoli administracyjnej, w tym do ról innych użytkowników."
      operator_hint: "Prowadzi gry na przepustki: przepustki, kody dostępu, przebieg gry. Bez dostępu do tej konsoli."
      anonymise_hint: "Usuwa dane osobowe, odłącza od drużyny i odbiera role; utworzone gry pozostają."
      delete_hint: "Usuwa konto w całości. Nieodwracalne."
```
```yaml
# tr
    user_page:
      profile: "Profil"
      roles: "Roller"
      team: "Takım"
      account: "Hesap"
      superadmin_hint: "Diğer kullanıcıların rolleri dahil yönetim konsoluna tam erişim."
      operator_hint: "Geçişli oyunları yürütür: geçişler, erişim kodları, oyun akışı. Bu konsola erişimi yoktur."
      anonymise_hint: "Kişisel verileri siler, takımdan ayırır ve rollerini kaldırır; oluşturduğu oyunlar kalır."
      delete_hint: "Hesabı tamamen siler. Geri alınamaz."
```
```yaml
# ka
    user_page:
      profile: "პროფილი"
      roles: "როლები"
      team: "გუნდი"
      account: "ანგარიში"
      superadmin_hint: "სრული წვდომა ადმინისტრირების კონსოლზე, მათ შორის სხვა მომხმარებლების როლებზე."
      operator_hint: "ატარებს საშვიან თამაშებს: საშვები, წვდომის კოდები, თამაშის მსვლელობა. ამ კონსოლზე წვდომის გარეშე."
      anonymise_hint: "შლის პირად მონაცემებს, აშორებს გუნდს და ართმევს როლებს; შექმნილი თამაშები რჩება."
      delete_hint: "მთლიანად შლის ანგარიშს. შეუქცევადია."
```

- [ ] **Step 5: CSS** (append)

```css

/* --- Admin console: the user page (admin/users/show) ----------------------- */
.admin-user-roles { display: flex; gap: var(--space-2); margin-bottom: var(--space-4); }
.admin-user .facts { margin-bottom: var(--space-4); }
.role-row { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2) var(--space-4); }
.role-row + .role-row { margin-top: var(--space-3); }
.role-row form { margin: 0; }
.role-hint { margin: 0; color: var(--text-dim); font-size: var(--text-sm); max-width: 52ch; }
```

- [ ] **Step 6: Run** — `bundle exec rspec spec/requests/admin_user_page_spec.rb spec/requests/admin_user_* spec/requests/superadmin_granting_spec.rb spec/requests/admin_operator_role_spec.rb spec/i18n_spec.rb spec/stylesheets` → PASS. The existing deletion/anonymisation "is offered … as a DELETE/POSTing form" examples must still pass unchanged.

- [ ] **Step 7: Mutation** — change `may_delete  = may_anon && @user.created_games.empty?` to `may_delete = may_anon`; `-e "author anonymise"` must fail. Restore.

- [ ] **Step 8: Commit** — `git commit -m "Group the superadmin's user page into profile, roles, team and account"`.

### Task 10: Teams list — disclosure and member truncation

**Files:**
- Modify: `app/views/admin/teams/index.html.erb` (members cell, actions cell), `public/stylesheets/screens.css`, seven locale files, `spec/requests/admin_teams_spec.rb` (append)

**Interfaces:**
- Produces: keys `admin.teams_list.{more,members_more}`; CSS `.row-more`.

- [ ] **Step 1: Failing examples** (append inside the top-level `describe` of `spec/requests/admin_teams_spec.rb`)

```ruby
  describe "row layout" do
    def row_for(team)
      Nokogiri::HTML(response.body).css("tbody tr").find { |tr| tr.text.include?(team.name) }
    end

    it "puts delete behind a closed disclosure, only for a deletable team" do
      empty = create_team
      busy  = create_team(:captain => captain)
      sign_in(superadmin)
      get admin_teams_path

      more = row_for(empty).at_css("details.row-more")
      expect(more).not_to be_nil
      expect(more["open"]).to be_nil
      expect(more.at_css("form[action='#{destroy_admin_team_path(empty)}']")).not_to be_nil
      expect(row_for(busy).at_css("details.row-more")).to be_nil
    end

    it "shows at most three members, then a count of the rest" do
      team = create_team(:captain => captain)
      5.times { team.members << create_user }
      sign_in(superadmin)
      get admin_teams_path

      cell = row_for(team).at_css("td.members")
      shown = team.members.order(:id).first(3).map(&:nickname)
      expect(cell.text).to include(shown.join(", "))
      expect(cell.text).to include("и ещё #{team.members.count - 3}")
      # Every member stays reachable: the captain picker lists them all.
      expect(row_for(team).css("select[name='member_id'] option").size).to eq(team.members.count)
    end
  end
```

(`captain` and `superadmin` are the file's existing `let`s; check the top of the file and use its names.)

- [ ] **Step 2: Run to verify it fails** — `bundle exec rspec spec/requests/admin_teams_spec.rb -e "row layout"` → FAIL.

- [ ] **Step 3: Change the view**

Members cell becomes:

```erb
      <%# One line however big the team: the first three, then a count. Every
          member is still listed in the captain picker in the last column. %>
      <% members = team.members.sort_by(&:id) %>
      <td class="members" data-label="<%= t("admin.teams.index.members") %>">
        <%= members.first(3).map(&:nickname).join(", ") %>
        <% if members.size > 3 %>
          <span class="members-more"><%= t("admin.teams_list.members_more", :count => members.size - 3) %></span>
        <% end %>
      </td>
```

In the actions `<td>`, replace the `if team.deletable?` block with the same block moved to the end of the cell and wrapped:

```erb
        <%# Rare and only ever on an empty, captainless team that never played,
            so it sits behind a disclosure rather than beside the everyday
            controls. A native <details>: no JavaScript. %>
        <% if team.deletable? %>
          <details class="row-more">
            <summary><%= t("admin.teams_list.more") %></summary>
            <%= button_to t("admin.teams.index.delete"), destroy_admin_team_path(team),
                          :method => :delete, :class => "btn btn--danger" %>
          </details>
        <% end %>
```

Wrap the remaining two controls («Вмешательство» link and the set-captain form) in `<div class="game-control">…</div>`.

- [ ] **Step 4: Keys** — `tmp/keys_teams_list.<l>.yml`:

```yaml
# ru
    teams_list:
      more: "Ещё"
      members_more: "и ещё %{count}"
# en
    teams_list:
      more: "More"
      members_more: "and %{count} more"
# uk
    teams_list:
      more: "Ще"
      members_more: "і ще %{count}"
# be
    teams_list:
      more: "Яшчэ"
      members_more: "і яшчэ %{count}"
# pl
    teams_list:
      more: "Więcej"
      members_more: "i %{count} więcej"
# tr
    teams_list:
      more: "Daha fazla"
      members_more: "ve %{count} kişi daha"
# ka
    teams_list:
      more: "მეტი"
      members_more: "და კიდევ %{count}"
```

(one file per locale, without the `# locale` lines.)

- [ ] **Step 5: CSS** (append)

```css

/* --- Admin console: the teams list (admin/teams/index) --------------------- */
.row-more { margin-top: var(--space-2); }
.row-more > summary { display: inline-flex; align-items: center; min-height: var(--tap); cursor: pointer; color: var(--text-dim); }
.row-more form { margin: var(--space-2) 0 0; }
.members-more { color: var(--text-dim); white-space: nowrap; }
```

- [ ] **Step 6: Run** — `bundle exec rspec spec/requests/admin_teams_spec.rb spec/requests/empty_states_a_spec.rb spec/i18n_spec.rb spec/stylesheets` → PASS.

- [ ] **Step 7: Mutation** — add `open` to `<details class="row-more" open>`; the "closed disclosure" example must fail. Restore.

- [ ] **Step 8: Commit** — `git commit -m "Tuck the teams list's delete behind a disclosure and cap the member line"`.

### Task 11: Measure the user page and teams list, gates, PR 3

- [ ] **Step 1: Add to `spec/layout/admin_console_layout_spec.rb`**

```ruby
  PEOPLE_PROBE = <<~JS
    var controls = Array.prototype.slice.call(document.querySelectorAll(".admin-user .btn, .admin-user select, main details.row-more > summary"));
    var details = Array.prototype.slice.call(document.querySelectorAll("details.row-more"));
    var RESULT = {
      count: controls.length,
      short: controls.filter(function (el) { return el.getBoundingClientRect().height < 43.5; }).map(function (el) { return el.outerHTML.slice(0, 80); }),
      openDetails: details.filter(function (d) { return d.open; }).length,
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "user page and teams list, #{theme} theme at #{width}x#{height} -- #{name}" do
        it "makes every user-page control full-size, without sideways scroll" do
          target = create_user
          create_team(:captain => create_user)
          m = measure_admin(superadmin_html(admin_user_path(target)), width, height, theme, PEOPLE_PROBE)
          expect(m["count"]).to be >= 5
          expect(m["short"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end

        it "keeps every teams-list disclosure closed and full-size" do
          2.times { create_team }
          m = measure_admin(superadmin_html(admin_teams_path), width, height, theme, PEOPLE_PROBE)
          expect(m["openDetails"]).to eq(0)
          expect(m["short"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end
      end
    end
  end
```

- [ ] **Step 2: Run** — `LAYOUT_SPECS=1 bundle exec rspec spec/layout/admin_console_layout_spec.rb` → 20 examples, 0 failures.

- [ ] **Step 3: CLAUDE.md** — finish the `admin_console_layout_spec.rb` clause ("…; every user-page control at least 44px; the teams list's disclosures closed and full-size"); recount locales (expected `ru=1202 be=1203`: 1192 + 10) and add the history sentence with the measured numbers.

- [ ] **Step 4: Gates** — full RSpec, Cucumber (238/2386), all layout specs, one after another.

- [ ] **Step 5: Commit, push, open PR 3**; owner approves → CI green → merge → clean up the worktree and branch.
