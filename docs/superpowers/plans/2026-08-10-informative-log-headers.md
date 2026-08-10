# Informative Log Headers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give all four log screens a shared header naming the game, the run, its date, its counts and its time zone, with links to the game's other runs.

**Architecture:** Two partials. `shared/_run_switcher` is **extracted** from `game_passings/show_results`, where it currently sits inline, and gains an explicit `linkable` array so each caller states its own policy. `shared/_run_context` is new and renders the header on the four `logs/` views. Switcher links are built from `request.path` plus merged query parameters — the idiom `shared/_pager` already uses — so one partial serves five pages whose path parameters differ.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec, ERB. No new gems.

**Spec:** `docs/superpowers/specs/2026-08-10-informative-log-headers-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix every command with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any file under `features/`.** This plan touches none.
- **Cucumber must stay at exactly 232 scenarios (230 passed, 2 undefined) / 2342 steps** after every task.
- **`Полный лог ответов` must survive as a contiguous substring** on the full-log page. Five frozen scenarios assert it six times via `have_text(:all, …)` (whitespace-normalised substring). The new title puts the game name **after** the phrase, never inside it.
- **The switcher renders nothing at all when the game has one run.** Same rule the pager follows for a single page; frozen scenarios render these screens for single-run games.
- **Every new user-facing string needs a key in all seven locale files** (`ru,en,uk,ka,tr,be,pl`). `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity.
- **No I18n pluralisation.** Counts use the colon form (`Команд: %{teams}`), never `one:`/`few:`/`many:`. No key in this app has ever used pluralisation.
- **Turkish never puts a case suffix on an interpolated value.** The new keys interpolate numbers and a game name; the game name takes `«%{game}» adlı oyunun …`.
- **Do not change who may see a log.** `ensure_author` and `ensure_full_log_access` are untouched — see spec §5 for why the obvious repair is wrong.
- **Hash-rocket style** (`:key => value`), comments in English, user-facing strings in Russian.
- Commit after every task.

---

### Task 1: Extract the run switcher into a shared partial

Behaviour on the results page must not change. This task only moves code and renames keys.

**Files:**
- Create: `app/views/shared/_run_switcher.html.erb`
- Modify: `app/views/game_passings/show_results.html.erb` (the inline switcher block)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Modify: `spec/requests/run_switcher_links_spec.rb`, `spec/requests/results_run_switcher_spec.rb`, `spec/requests/timezone_rendering_spec.rb`

**Interfaces:**
- Produces: `render "shared/run_switcher", :runs => …, :current => …, :linkable => …` where `runs` is an ordered collection of `GameRun`, `current` is the displayed `GameRun`, and `linkable` is an **array of runs that may be offered as links**. Task 2 calls this.
- Produces: locale keys `shared.times_in_zone`, `shared.run_switcher.heading`, `shared.run_switcher.run_label`.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/results_run_switcher_spec.rb`, before its final `end`:

```ruby
  # The extraction must not change what the results page offers. These pin the
  # two halves of its policy -- a started run is linked, an unstarted one is
  # named but not linked -- against the shared partial rather than the inline
  # block it replaced.
  describe "after the switcher moved to a shared partial" do
    it "links a started earlier run" do
      game.open_run!(:starts_at => 2.years.from_now,
                     :registration_deadline => 23.months.from_now,
                     :max_team_number => 10)
      game.reload
      set_game_schedule!(game, :starts_at => 1.hour.ago)

      get game_passings_show_results_path(:game_id => game.id)

      expect(Capybara.string(response.body)).to have_link(:href => %r{run=1})
    end

    it "names but does not link a run that has not started" do
      game.open_run!(:starts_at => 2.years.from_now,
                     :registration_deadline => 23.months.from_now,
                     :max_team_number => 10)
      game.reload

      get game_passings_show_results_path(:game_id => game.id)

      page = Capybara.string(response.body)
      expect(page.text).to include("Забег №2")
      expect(page).to have_no_link(:href => %r{run=2})
    end
  end
```

- [ ] **Step 2: Run it to verify it passes against the current inline block**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/results_run_switcher_spec.rb
```

Expected: PASS. These are characterisation examples — they must be green **before** the extraction so that a red result afterwards means the extraction changed behaviour. If they fail now, stop: the fixture setup is wrong, not the code.

- [ ] **Step 3: Move the three locale keys**

In each of the seven files, **delete** these three keys from under `game_passings: → show_results:`:

```yaml
      times_in_zone: …
      runs_heading: …
      run_label: …
```

and add them under the existing top-level `shared:` block, keeping each value byte-identical to the one you deleted. For `ru.yml` the result is:

```yaml
  shared:
    times_in_zone: "Время показано в поясе %{zone}"
    run_switcher:
      heading: "Забеги:"
      run_label: "Забег №%{ordinal} — %{date}"
    pager:
      previous: "‹ Назад"
```

**Merge into the `shared:` block that already exists** — every file has one, holding `pager:` and `game_entry_controls:`. A second `shared:` key silently wins over the first in YAML.

There is deliberately **no key for the missing-date dash**: the partial inlines `"—"`, exactly as the code being extracted does. A key whose value is `"—"` in every language would trip `spec/i18n_spec.rb`'s untranslated-copy guard and need an exemption for nothing.

- [ ] **Step 4: Create the partial**

Create `app/views/shared/_run_switcher.html.erb`:

```erb
<%# Extracted from game_passings/show_results, where this was inline.
    `linkable` is an explicit array rather than a predicate so each caller
    states its own policy and this partial holds none:

      * the results page may link only runs whose results_visible? is true --
        its started-run guard refuses the rest, and offering a link the guard
        answers with a bare 401 is a defect this programme already shipped
        once;
      * the log screens have no started-run guard (ensure_author and
        ensure_full_log_access only), so every run they name is one they will
        serve.

    Nothing at all for a game with one run: that is most games in production,
    and several frozen scenarios render these pages.

    Hrefs are built from request.path plus the existing query parameters, the
    same idiom shared/_pager uses. `run` is a query parameter on all five
    pages that render this, whose PATH parameters differ, so this needs no
    per-caller route helper -- and ?run= and ?page= survive each other. %>
<% if runs.size > 1 %>
  <p class="run-switcher">
    <strong><%= t("shared.run_switcher.heading") %></strong>
    <% runs.each do |run| %>
      <% label = t("shared.run_switcher.run_label",
                   :ordinal => run.ordinal,
                   :date => run.starts_at ? l(run.starts_at.to_date, :format => :long) : "—") %>
      <% if run == current || !linkable.include?(run) %>
        <strong><%= label %></strong>
      <% else %>
        <%= link_to label,
                    "#{request.path}?#{request.query_parameters.merge("run" => run.ordinal).to_query}" %>
      <% end %>
    <% end %>
  </p>
<% end %>
```

- [ ] **Step 5: Call it from the results page**

In `app/views/game_passings/show_results.html.erb`, replace the whole block from `<%# Nothing at all for a game with one run:` through its closing `<% end %>` with:

```erb
<%= render "shared/run_switcher", :runs => @game.runs, :current => @run,
                                  :linkable => @game.runs.select(&:results_visible?) %>
```

and change the zone statement's key on the line above it from
`t("game_passings.show_results.times_in_zone", …)` to `t("shared.times_in_zone", …)`.
**Leave `zone_reference` alone** — Task 3 fixes which run it reads.

- [ ] **Step 6: Point the three specs at the new keys**

- `spec/requests/run_switcher_links_spec.rb:36` — `I18n.t("game_passings.show_results.run_label", …)` → `I18n.t("shared.run_switcher.run_label", …)`
- `spec/requests/run_switcher_links_spec.rb:78` — `…show_results.runs_heading` → `shared.run_switcher.heading`
- `spec/requests/results_run_switcher_spec.rb:123` and `:136` — `…show_results.runs_heading` → `shared.run_switcher.heading`
- `spec/requests/timezone_rendering_spec.rb:67` and `:68` — `…show_results.times_in_zone` → `shared.times_in_zone`

- [ ] **Step 7: Run the specs, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/results_run_switcher_spec.rb spec/requests/run_switcher_links_spec.rb spec/requests/timezone_rendering_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: PASS throughout; Cucumber **232 / 2342**.

- [ ] **Step 8: Commit**

```bash
git add app/views/shared/_run_switcher.html.erb app/views/game_passings/show_results.html.erb config/locales spec/
git commit -m "Extract the run switcher into a shared partial

Behaviour on the results page is unchanged; two characterisation
examples were made green before the move so that a red result after it
would mean the extraction changed something.

linkable is an explicit array rather than a predicate, so each caller
states its own policy and the partial holds none -- the results page may
link only runs whose results_visible? is true, while the log screens
have no started-run guard and may link every run.

Hrefs come from request.path plus merged query parameters rather than a
route helper: run is a query parameter on all five pages that render
this, whose path parameters differ."
```

---

### Task 2: The run-context header on all four log screens

**Files:**
- Create: `app/views/shared/_run_context.html.erb`
- Modify: `app/controllers/logs_controller.rb`
- Modify: `app/views/logs/show_full_log.html.erb`, `show_live_channel.html.erb`, `show_game_log.html.erb`, `show_level_log.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/log_run_context_spec.rb` (create)

**Interfaces:**
- Consumes: `render "shared/run_switcher", :runs =>, :current =>, :linkable =>` from Task 1.
- Produces: `@run_team_count` and `@game_level_count` on every `LogsController` action; locale keys `shared.run_context.counts` and a reworded `logs.show_full_log.title` taking `%{game}`.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/log_run_context_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The four log screens each show answers from exactly one run of one game and
# said almost nothing about which. The full log was the only one whose title
# named no subject at all, and none of the four named its run -- despite all
# four accepting ?run= with no UI that produces such a URL.
describe "the log screens' run context", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false, :name => "Викторина")
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def play(run)
    create_game_passing(:level => level, :team => team, :game_run => run)
    create_log(:game => game, :level => level, :team => team,
               :game_run => run, :answer => "код")
  end

  def open_second_run
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game.reload
  end

  before { play(game.current_run) }

  # The frozen phrase must survive contiguously: five scenarios assert
  # "Полный лог ответов" through have_text(:all, ...), a whitespace-normalised
  # substring match. The game name goes AFTER it, never inside it.
  it "names the game in the full log's title, keeping the frozen phrase intact" do
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include("Полный лог ответов")
    expect(response.body).to include("Викторина")
  end

  it "names the run and its date on every log screen" do
    sign_in(author)
    expected = I18n.t("shared.run_switcher.run_label",
                      :ordinal => 1,
                      :date => I18n.l(game.current_run.starts_at.to_date, :format => :long))

    [ show_full_log_path(:game_id => game.id),
      show_live_channel_path(:game_id => game.id),
      show_game_log_path(:game_id => game.id, :team_id => team.id),
      show_level_log_path(:game_id => game.id, :team_id => team.id) ].each do |path|
      get path
      expect(response.body).to include(expected), "expected #{path} to name run 1"
    end
  end

  # ?run=1 must label itself run 1, not the run that happens to be current.
  it "names the run being viewed, not the current one" do
    open_second_run
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include("Забег №1")
  end

  # A draft game's run has no start date. Rendering "—" rather than raising is
  # the same rule the switcher already followed.
  it "renders a dash for a run with no start date" do
    game.current_run.update_column(:starts_at, nil)
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Забег №1")
  end

  # The counts describe the RUN, not the game -- the same distinction that
  # produced the @teams scoping bug in the run-scoped-logs work, where a
  # game-scoped query returned plausible but wrong rows.
  it "counts the teams of the run being viewed, not of the game" do
    open_second_run
    other = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => other, :game_run => game.current_run)
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(
      I18n.t("shared.run_context.counts", :teams => 1, :levels => 1))
  end

  it "offers the other run as a link on all four screens" do
    open_second_run
    sign_in(author)

    [ show_full_log_path(:game_id => game.id),
      show_live_channel_path(:game_id => game.id),
      show_game_log_path(:game_id => game.id, :team_id => team.id),
      show_level_log_path(:game_id => game.id, :team_id => team.id) ].each do |path|
      get path
      expect(Capybara.string(response.body))
        .to have_link(:href => %r{run=1}), "expected #{path} to link run 1"
    end
  end

  # ?run= and ?page= must survive each other: the href is built from
  # request.path plus the EXISTING query parameters, so switching run from
  # page 2 stays on page 2 rather than silently returning to the first.
  it "keeps the page when switching run, and the run when paging" do
    25.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    open_second_run
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :page => 2)

    page = Capybara.string(response.body)
    expect(page).to have_link(:href => %r{page=2})
    expect(page).to have_link(:href => %r{run=1})
    expect(page.find_link(:href => %r{run=1})[:href]).to include("page=2")
  end

  # THE frozen-scenario guard: features/logs/log.feature renders these pages
  # for single-run games, and a switcher where there was none would change
  # what they read.
  it "renders no switcher at all for a game with one run" do
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).not_to include(I18n.t("shared.run_switcher.heading"))
  end

  # Derived from the RUN on screen. Game#starts_at delegates to current_run,
  # so a game with a second run would otherwise report run 2's offset while
  # displaying run 1 -- wrong across a DST boundary.
  it "states the offset of the run being viewed" do
    author.update!(:timezone => "Berlin")
    game.current_run.update_column(:starts_at, Time.utc(2024, 8, 6, 9, 0, 0))
    open_second_run
    game.current_run.update_column(:starts_at, Time.utc(2024, 12, 15, 9, 0, 0))
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(I18n.t("shared.times_in_zone", :zone => "+02:00"))
    expect(response.body).not_to include(I18n.t("shared.times_in_zone", :zone => "+01:00"))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/log_run_context_spec.rb
```

Expected: FAIL — `shared.run_context.counts` raises `I18n::MissingTranslationData`, and no log screen names its run.

- [ ] **Step 3: Add the counts key in all seven files**

Under the existing top-level `shared:` block, as a sibling of `run_switcher:`:

```yaml
# ru.yml
    run_context:
      counts: "Команд: %{teams} · Уровней: %{levels}"
# en.yml
    run_context:
      counts: "Teams: %{teams} · Levels: %{levels}"
# uk.yml
    run_context:
      counts: "Команд: %{teams} · Рівнів: %{levels}"
# be.yml
    run_context:
      counts: "Каманд: %{teams} · Узроўняў: %{levels}"
# pl.yml
    run_context:
      counts: "Drużyn: %{teams} · Poziomów: %{levels}"
# tr.yml
    run_context:
      counts: "Takım sayısı: %{teams} · Seviye sayısı: %{levels}"
# ka.yml
    run_context:
      counts: "გუნდები: %{teams} · დონეები: %{levels}"
```

Both placeholders are numbers, so no Turkish case suffix lands on a user-authored value.

- [ ] **Step 4: Reword the full log's title in all seven files**

Replace `logs: → show_full_log: → title:`:

```yaml
# ru.yml
      title: "Полный лог ответов игры «%{game}»"
# en.yml
      title: "Full answer log for “%{game}”"
# uk.yml
      title: "Повний лог відповідей гри «%{game}»"
# be.yml
      title: "Поўны лог адказаў гульні «%{game}»"
# pl.yml
      title: "Pełny dziennik odpowiedzi gry „%{game}”"
# tr.yml
      title: "«%{game}» adlı oyunun tam yanıt kaydı"
# ka.yml
      title: "თამაშის «%{game}» პასუხების სრული ჟურნალი"
```

The Russian value **begins** with `Полный лог ответов`, unbroken — that is what keeps the six frozen assertions matching. This key has exactly one caller (the view below); the link texts the frozen scenarios click come from `game_passings.index.full_log` and `games.list.full_log`, which are **not** changed.

- [ ] **Step 5: Count the run in the controller**

In `app/controllers/logs_controller.rb`, add the filter after `find_run`:

```ruby
  before_action :count_the_run
```

and the method beside `find_run`:

```ruby
  # Two COUNTs on every log screen, for the header. show_full_log also loads
  # @teams as objects and so pays one redundant COUNT: one filter that behaves
  # identically on four screens is worth more than the single query it would
  # save on one of them, and the header must not vary by screen.
  #
  # Teams are counted through the RUN; levels through the GAME, because levels
  # are the game's content and are shared by every running of it.
  def count_the_run
    @run_team_count   = GamePassing.where(:game_run_id => @run.id).count
    @game_level_count = Level.of_game(@game).count
  end
```

- [ ] **Step 6: Create the header partial**

Create `app/views/shared/_run_context.html.erb`:

```erb
<%# Context for the run whose answers are on screen, rendered by all four log
    views. Each of them names its own subject -- team, level, game -- but none
    named its RUN, and all four have accepted ?run= since the run-scoped-logs
    change with no UI that produces such a URL. %>
<p class="run-context">
  <strong><%= t("shared.run_switcher.run_label",
                :ordinal => @run.ordinal,
                :date => @run.starts_at ? l(@run.starts_at.to_date, :format => :long) : "—") %></strong>
</p>

<p><%= t("shared.run_context.counts",
         :teams => @run_team_count, :levels => @game_level_count) %></p>

<%# Every run is linkable: no started-run guard applies to these screens, so
    unlike the results page there is no run this can name and then refuse. %>
<%= render "shared/run_switcher", :runs => @game.runs, :current => @run,
                                  :linkable => @game.runs %>

<%# Derived from the RUN being displayed, never from @game: Game#starts_at
    delegates to current_run, so on a game with a second run that would report
    run 2's offset while the times below belong to run 1. Falls back to now
    when the run has no start date, as the results page does. %>
<% zone_reference = (@run.starts_at || Time.current).in_time_zone(Time.zone) %>
<p><em><%= t("shared.times_in_zone", :zone => zone_reference.formatted_offset) %></em></p>
```

- [ ] **Step 7: Render it on all four log views**

`app/views/logs/show_full_log.html.erb` — replace the `<h1>` line with:

```erb
<h1><%= t("logs.show_full_log.title", :game => @game.name) %></h1>

<%= render "shared/run_context" %>
```

`app/views/logs/show_live_channel.html.erb` — after the `<h2>` line:

```erb
<%= render "shared/run_context" %>
```

`app/views/logs/show_game_log.html.erb` — after the `<h1>` line:

```erb
<%= render "shared/run_context" %>
```

`app/views/logs/show_level_log.html.erb` — after the `<h1>` line:

```erb
<%= render "shared/run_context" %>
```

- [ ] **Step 8: Run the spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/log_run_context_spec.rb spec/requests/run_scoped_logs_spec.rb spec/requests/log_pagination_spec.rb spec/views/logs_spec.rb spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: PASS; Cucumber **232 / 2342**.

`spec/views/logs_spec.rb` renders these templates directly with `assign(...)`, so it will need `assign(:run, …)`, `assign(:run_team_count, …)` and `assign(:game_level_count, …)` added to each of its four examples — the same reason it needed `assign(:page, 1)` when the pager landed. Add them; do not make the partial tolerate nils, for the same reason the pager does not: a nil there means a controller forgot the filter, and rendering nothing would hide it.

If Cucumber moves, the likely cause is the switcher appearing on a single-run game — check that guard first.

- [ ] **Step 9: Commit**

```bash
git add app/views/shared/_run_context.html.erb app/controllers/logs_controller.rb app/views/logs config/locales spec/
git commit -m "Say which game and which run a log belongs to

All four log screens showed answers from one run of one game and said
almost nothing about which. The full log was the only one whose title
named no subject at all, and none of the four named its run -- despite
all four accepting ?run= since the run-scoped-logs change, with no UI
that produced such a URL. The switcher is that UI.

The counts describe the RUN (teams that played it) and the GAME
(levels), which is the same distinction that produced the @teams
scoping bug: a game-scoped query here would return a plausible but
wrong number.

The zone statement is derived from the run on screen rather than
@game.starts_at, which delegates to current_run and would report the
wrong offset for an earlier run across a DST boundary.

The Russian title still begins with the unbroken phrase
'Полный лог ответов', which is what six frozen assertions match."
```

---

### Task 3: The results page states its own run's zone

**Files:**
- Modify: `app/views/game_passings/show_results.html.erb` (the `zone_reference` line)
- Test: `spec/requests/timezone_rendering_spec.rb` (extend)

**Interfaces:**
- Consumes: `shared.times_in_zone` from Task 1.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/timezone_rendering_spec.rb`, inside the same `describe` block as the existing offset example:

```ruby
  # @game.starts_at delegates to current_run (Game#starts_at), so a game with
  # a second run computed its offset from the run the viewer is NOT looking at.
  # Run 1 is in August (Berlin, CEST +02:00) and run 2 in December (CET
  # +01:00), so the two disagree and the example can actually fail.
  it "states the offset of the run being viewed, not of the current run" do
    user.update!(:timezone => "Berlin")
    game = create_game(:is_draft => false)
    level = create_level(:game => game)
    set_game_schedule!(game, :starts_at => Time.utc(2024, 8, 6, 9, 0, 0))
    create_game_passing(:level => level, :game_run => game.current_run,
                        :finished_at => Time.utc(2024, 8, 6, 11, 30, 0))

    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
    game.current_run.update_column(:starts_at, Time.utc(2024, 12, 15, 9, 0, 0))

    get game_passings_show_results_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(I18n.t("shared.times_in_zone", :zone => "+02:00"))
    expect(response.body).not_to include(I18n.t("shared.times_in_zone", :zone => "+01:00"))
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/timezone_rendering_spec.rb -e "the run being viewed"
```

Expected: FAIL — the page states `+01:00`, run 2's winter offset, while showing run 1's August times.

- [ ] **Step 3: Read the offset off the displayed run**

In `app/views/game_passings/show_results.html.erb`, change:

```erb
<% zone_reference = (@game.starts_at || Time.current).in_time_zone(Time.zone) %>
```

to:

```erb
<%# @run, not @game: Game#starts_at delegates to current_run, so viewing an
    earlier run's results computed the offset from the CURRENT run's start
    date -- a different answer across a DST boundary, printed next to times
    that disagree with it. %>
<% zone_reference = (@run.starts_at || Time.current).in_time_zone(Time.zone) %>
```

- [ ] **Step 4: Run the spec, then both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/timezone_rendering_spec.rb
bundle exec rspec
bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: PASS; Cucumber **232 / 2342**; `All is good!`.

- [ ] **Step 5: Commit**

```bash
git add app/views/game_passings/show_results.html.erb spec/requests/timezone_rendering_spec.rb
git commit -m "State the results page's zone from the run being viewed

@game.starts_at delegates to current_run, so a game with a second run
computed its offset from the run the viewer was not looking at. Across
a DST boundary that printed the wrong zone label directly above times
that disagreed with it.

Pinned with run 1 in August (CEST +02:00) and run 2 in December (CET
+01:00), so the two genuinely differ and the example can fail."
```

---

## Notes for the implementer

**Task 1 changes no behaviour.** Its two new examples are characterisation tests: make them green *before* the extraction. A red result afterwards means the move changed something.

**Three things that look wrong and are not:**

1. **`linkable` is an array, not a predicate.** The two callers have genuinely different policies and the partial must hold neither.
2. **The counts filter pays one redundant `COUNT` on the full log.** Deliberate — see the comment in `count_the_run`.
3. **`_run_context` reads instance variables rather than taking locals.** It is rendered by four views of one controller, all of which set the same three; passing them as locals four times would be noise. `_run_switcher` takes locals because it has two callers in *different* controllers.

**Do not "fix" `ensure_full_log_access`** while you are in this file. Spec §5: the `current_run` it reads is simultaneously the access gap and the thing stopping a finished player from reading a live run. The obvious repair trades a bug for a leak.
