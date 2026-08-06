# Games Listing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `/games` from a bare list of names into a listing showing each game's status, start, end and participant counts.

**Architecture:** Three independent layers, each shippable on its own. Task 1 extracts `Game#status`, replacing two hand-synchronised copies of the same precedence with one method. Task 2 extracts the elapsed-time formatting that `GamePassing` currently keeps private behind a standing `TODO`. Task 3 rebuilds the listing on top of both, with the team counts loaded by a helper rather than the controller — the partial has two render sites and only one of them is `GamesController`.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, sqlite (dev/test), RSpec, Cucumber (Russian Gherkin). No asset pipeline — plain CSS in `public/stylesheets/`, no build step.

## Global Constraints

- Ruby is not on `PATH` in non-login shells. Prefix every command: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- Baseline that must hold: **762 rspec examples / 0 failures / 6 pending**, and **234 cucumber
  scenarios (2 pre-existing "undefined") / 2362 steps** — MEASURED on master at `634d30e`,
  not carried over from when this plan was written. The figure originally written here (711)
  predates PRs #17-#22 and is wrong; every per-task example count below is therefore an
  increment on 762, not on the number printed in that task.
- `features/**/*.feature` is **read-only for this entire plan**. No exceptions. Three feature files drive this listing and every one of them must keep passing untouched.
- Every user-facing string is a `t()` key present in **all four** of `config/locales/{ru,en,uk,ka}.yml`. Use the exact translations given in this plan.
- No new colour or spacing literals — tokens live in `public/stylesheets/tokens.css`. Reuse the existing `.tag`, `.tag--live`, `.tag--danger`, `.table--cards` and `.table-wrap` components.
- Hash rockets (`:key => value`) for symbol keys; match the surrounding file.

---

### Task 1: Extract `Game#status`

**Files:**
- Modify: `app/models/game.rb` (add `#status`; `count_by_status` at ~line 182 keeps its SQL)
- Modify: `app/views/admin/games/index.html.erb:23-33` (replace the `if/elsif` chain)
- Test: `spec/models/game/status_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Game#status` → one of `:withdrawn`, `:draft`, `:finished`, `:running`, `:scheduled`.

**Why this exists.** The precedence withdrawn → draft → finished → running → scheduled is implemented twice today: once in SQL in `Game.count_by_status`, once as an `if/elsif` chain in the admin games view. `count_by_status` carries a comment stating the two must agree — a comment doing a method's job. The listing in Task 3 would be the third copy.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/game/status_spec.rb`:

```ruby
require "rails_helper"

describe Game, "#status" do
  # A running game fails its own validations (game_starts_in_the_future fires
  # when author_finished_at is nil and starts_at is past), so every write to a
  # live game row goes through update_column.
  def running_game
    game = create_game(:is_draft => false)
    game.update_column(:starts_at, 1.hour.ago)
    game
  end

  it "is :scheduled for a published game that has not started" do
    expect(create_game(:is_draft => false).status).to eq(:scheduled)
  end

  it "is :scheduled for a published game with no start time at all" do
    game = create_game(:is_draft => false)
    game.update_column(:starts_at, nil)

    expect(game.status).to eq(:scheduled)
  end

  it "is :running once the start time has passed" do
    expect(running_game.status).to eq(:running)
  end

  it "is :draft for a draft" do
    expect(create_game(:is_draft => true).status).to eq(:draft)
  end

  it "is :finished once the author has ended it" do
    game = running_game
    game.update_column(:author_finished_at, Time.now)

    expect(game.status).to eq(:finished)
  end

  it "is :withdrawn for a withdrawn game" do
    game = create_game(:is_draft => false)
    game.withdraw!

    expect(game.status).to eq(:withdrawn)
  end

  # The predicates overlap by construction, so the ORDER is load-bearing.
  # These two pin it: without the precedence they would return :finished and
  # :draft respectively.
  it "reports :withdrawn for a game that is both withdrawn and finished" do
    game = running_game
    game.update_column(:author_finished_at, Time.now)
    game.withdraw!

    expect(game.status).to eq(:withdrawn)
  end

  it "reports :draft for a draft whose start time has passed" do
    game = create_game(:is_draft => true)
    game.update_column(:starts_at, 1.hour.ago)

    expect(game.status).to eq(:draft)
  end

  # Pausing and editing-locking are orthogonal: a game can be paused AND
  # running. Folding either into the precedence would hide one fact in order
  # to show the other -- the same reasoning count_by_status already documents
  # for locking.
  it "still reports :running for a paused game" do
    game = running_game
    game.pause!

    expect(game.status).to eq(:running)
  end

  it "still reports :running for an editing-locked game" do
    game = running_game
    game.lock_editing!

    expect(game.status).to eq(:running)
  end

  # THE guard the comment on count_by_status was standing in for. Two screens
  # disagreeing about what a game IS would be worse than either being wrong.
  it "agrees with count_by_status across every state" do
    create_game(:is_draft => true)
    create_game(:is_draft => false)
    running_game
    finished = running_game
    finished.update_column(:author_finished_at, Time.now)
    create_game(:is_draft => false).withdraw!

    tallied = Game.all.group_by(&:status).transform_values(&:size)
    tallied.default = 0
    counted = Game.count_by_status

    expect(counted[:withdrawn]).to eq(tallied[:withdrawn])
    expect(counted[:draft]).to     eq(tallied[:draft])
    expect(counted[:finished]).to  eq(tallied[:finished])
    expect(counted[:running]).to   eq(tallied[:running])
    expect(counted[:scheduled]).to eq(tallied[:scheduled])
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/status_spec.rb
```

Expected: every example fails with `NoMethodError: undefined method 'status'`.

- [ ] **Step 3: Add the method**

In `app/models/game.rb`, immediately above `def self.count_by_status`:

```ruby
  # The single source of truth for what a game IS. The predicates overlap by
  # construction -- a withdrawn game may also be finished, a draft may have a
  # start time in the past -- so the ORDER is load-bearing, not stylistic.
  #
  # paused? and editing_locked? are deliberately NOT here: a game can be
  # paused AND running, and folding either in would hide one fact in order to
  # show the other. Both are reported alongside the status, never instead of
  # it -- the same reasoning count_by_status documents for locking.
  #
  # count_by_status below applies this same precedence in SQL, because
  # counting must not load every row. The two are pinned to each other by
  # spec/models/game/status_spec.rb rather than by a comment asking future
  # readers to keep them in step.
  def status
    return :withdrawn if withdrawn?
    return :draft     if draft?
    return :finished  if author_finished?
    return :running   if started?
    :scheduled
  end
```

Then update the comment on `count_by_status` (~line 175): replace the sentence beginning "The order matches how the admin console labels a game" with:

```ruby
  # The order matches Game#status above, which is what every screen uses to
  # label an individual game. Counting is done in SQL rather than through
  # that method because a counter must not load every row.
```

- [ ] **Step 4: Run the spec**

```bash
bundle exec rspec spec/models/game/status_spec.rb
```

Expected: PASS, 11 examples.

- [ ] **Step 5: Replace the admin view's chain**

In `app/views/admin/games/index.html.erb`, replace lines 23–33 (the `if/elsif` block inside the status `<td>`) with:

```erb
        <% case game.status
           when :withdrawn %><span class="tag tag--danger"><%= t("admin.games.index.withdrawn") %></span>
        <% when :draft     %><span class="tag"><%= t("admin.games.index.draft") %></span>
        <% when :finished  %><span class="tag"><%= t("admin.games.index.finished") %></span>
        <% when :running   %><span class="tag tag--live"><%= t("admin.games.index.running") %></span>
        <% else            %><span class="tag"><%= t("admin.games.index.scheduled") %></span>
        <% end %>
```

Leave the `editing_locked?` line immediately below it exactly as it is — locking is reported alongside the status, not instead of it.

- [ ] **Step 6: Run the full suite**

```bash
bundle exec rspec
bundle exec cucumber
```

Expected: **762 + 11 = 773 examples, 0 failures, 6 pending**; cucumber unchanged at **234 / 2362**.
If your total differs, re-measure the baseline before assuming something is wrong — every plan in
this repository has carried a stale predicted total at least once. Report the actual numbers.

- [ ] **Step 7: Commit**

```bash
git add app/models/game.rb app/views/admin/games/index.html.erb spec/models/game/status_spec.rb
git commit -m "Extract Game#status, replacing two hand-synchronised copies

The precedence withdrawn -> draft -> finished -> running -> scheduled existed
twice: once in SQL in count_by_status, once as an if/elsif chain in the admin
games view. count_by_status carried a comment explaining the two must agree,
which is a comment doing a method's job.

A spec now pins count_by_status to Game#status across all five states, so the
two cannot drift. Pausing and editing-locking stay outside the precedence --
a game can be paused AND running, and folding either in would hide one fact
to show the other."
```

---

### Task 2: Extract the elapsed-time formatting

**Files:**
- Create: `app/models/concerns/time_formatting.rb`
- Modify: `app/models/game_passing.rb` (`#time_at_level` ~line 186; delete `seconds_fraction_to_time` ~line 288)
- Modify: `app/helpers/application_helper.rb`
- Test: `spec/models/concerns/time_formatting_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `TimeFormatting#seconds_to_hms(seconds)` → `"HH:MM:SS"`; `TimeFormatting#hours_and_minutes(seconds)` → `[hours, minutes]`. Both available on `GamePassing` instances and in every view.

**Why this exists.** `GamePassing#seconds_fraction_to_time` is private and carries a standing `# TODO: keep SRP, extract this to a separate helper`. Task 3 needs the same arithmetic to render a game's duration. Extracting resolves the TODO instead of adding a third formatting of elapsed time.

The module stays free of `t()` — it returns numbers and a fixed digit format. Words like "hours" come from locale keys at the call site, so the module has no locale to be wrong about.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/concerns/time_formatting_spec.rb`:

```ruby
require "rails_helper"

describe TimeFormatting do
  let(:subject) { Class.new { include TimeFormatting }.new }

  describe "#seconds_to_hms" do
    it "renders under a minute as zero-padded seconds" do
      expect(subject.seconds_to_hms(7)).to eq("00:00:07")
    end

    it "renders minutes and seconds" do
      expect(subject.seconds_to_hms(125)).to eq("00:02:05")
    end

    it "renders hours, minutes and seconds" do
      expect(subject.seconds_to_hms(3725)).to eq("01:02:05")
    end

    it "does not wrap past 24 hours" do
      expect(subject.seconds_to_hms(90_000)).to eq("25:00:00")
    end

    it "truncates a fractional interval rather than rounding it" do
      expect(subject.seconds_to_hms(59.9)).to eq("00:00:59")
    end

    it "renders zero" do
      expect(subject.seconds_to_hms(0)).to eq("00:00:00")
    end
  end

  describe "#hours_and_minutes" do
    it "splits an interval into whole hours and remaining whole minutes" do
      expect(subject.hours_and_minutes(3725)).to eq([1, 2])
    end

    it "returns zero hours for a short interval" do
      expect(subject.hours_and_minutes(125)).to eq([0, 2])
    end

    it "returns zeroes for an interval under a minute" do
      expect(subject.hours_and_minutes(30)).to eq([0, 0])
    end
  end
end

describe GamePassing, "#time_at_level after the extraction" do
  it "still renders the elapsed time in the same HH:MM:SS format" do
    passing = create_game_passing
    passing.update_column(:current_level_entered_at, 3725.seconds.ago)

    expect(passing.time_at_level).to match(/\A01:02:0\d\z/)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bundle exec rspec spec/models/concerns/time_formatting_spec.rb
```

Expected: fails with `NameError: uninitialized constant TimeFormatting`.

- [ ] **Step 3: Create the module**

Create `app/models/concerns/time_formatting.rb`:

```ruby
# Elapsed-interval formatting, shared by the model that measures time at a
# level and the views that render how long a game ran. Extracted from
# GamePassing#seconds_fraction_to_time, which was private and carried a
# standing "TODO: keep SRP, extract this to a separate helper".
#
# Deliberately free of t(): it returns numbers and a fixed digit format, so
# there is no locale for it to be wrong about. Words like "hours" belong to
# the locale keys at the call site.
module TimeFormatting
  # "HH:MM:SS", not wrapped at 24 hours -- a team can legitimately sit on one
  # level longer than a day, and 25:00:00 says that where 01:00:00 would lie.
  def seconds_to_hms(seconds)
    total   = seconds.to_i
    hours   = total / 3600
    minutes = (total % 3600) / 60
    secs    = total % 60

    "%02d:%02d:%02d" % [hours, minutes, secs]
  end

  # Whole hours and the remaining whole minutes, for prose durations.
  def hours_and_minutes(seconds)
    total = seconds.to_i
    [total / 3600, (total % 3600) / 60]
  end
end
```

- [ ] **Step 4: Use it in `GamePassing`**

In `app/models/game_passing.rb`, add below the `serialize` line:

```ruby
  include TimeFormatting
```

Replace `#time_at_level` (~line 186) with:

```ruby
  def time_at_level
    seconds_to_hms(effective_now - self.current_level_entered_at)
  end
```

Delete `seconds_fraction_to_time` entirely (~line 288, together with its `# TODO: keep SRP` comment).

First confirm nothing else calls it:

```bash
grep -rn "seconds_fraction_to_time" app/ spec/ features/ lib/
```

Expected: no matches after the deletion. If there are other callers, point them at `seconds_to_hms` rather than keeping the old method.

- [ ] **Step 5: Make it available to views**

In `app/helpers/application_helper.rb`, immediately inside `module ApplicationHelper`:

```ruby
  # Shared with GamePassing rather than reimplemented: the listing renders how
  # long a game ran, which is the same arithmetic the play screen uses for
  # time at a level.
  include TimeFormatting
```

- [ ] **Step 6: Run the specs**

```bash
bundle exec rspec spec/models/concerns/time_formatting_spec.rb
bin/rails zeitwerk:check
bundle exec rspec
```

Expected: the new file passes (10 examples); `zeitwerk:check` prints `All is good!`; the full suite is
**773 + 10 = 783 examples, 0 failures, 6 pending**. Report the actual numbers.

- [ ] **Step 7: Commit**

```bash
git add app/models/concerns/time_formatting.rb app/models/game_passing.rb \
        app/helpers/application_helper.rb spec/models/concerns/time_formatting_spec.rb
git commit -m "Extract elapsed-time formatting into TimeFormatting

Resolves the standing 'TODO: keep SRP, extract this to a separate helper' on
GamePassing#seconds_fraction_to_time. The games listing needs the same
arithmetic to render how long a game ran, and a third copy of it was the
alternative.

The module returns numbers and a fixed digit format with no t() call, so it
has no locale to be wrong about -- words belong to the locale keys at the
call site. HH:MM:SS still does not wrap at 24 hours: a team can sit on one
level longer than a day, and 25:00:00 says so where 01:00:00 would lie."
```

---

### Task 3: Rebuild the listing

**Files:**
- Create: `app/helpers/games_helper.rb`
- Modify: `app/views/games/_list.html.erb` (full rewrite)
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/games_listing_spec.rb`
- **No stylesheet changes.** `.table--cards`, `.table-wrap` and `.tag*` already exist and are reused as-is (see Step 6).

**Interfaces:**
- Consumes: `Game#status` (Task 1), `TimeFormatting#hours_and_minutes` (Task 2).
- Produces: `GamesHelper#game_team_counts(games)`, `#game_duration_text(game)`, `#game_status_tag(game)`.

**The two-render-sites constraint.** `games/_list` is rendered from `app/views/games/index.html.erb:1` **and** `app/views/dashboard/_my_games.html.erb:7`. The counts therefore cannot be assigned by `GamesController#index` — the dashboard would render the partial without them and crash. They are loaded by a helper the partial calls, so both sites work unchanged.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/games_listing_spec.rb`:

```ruby
require "rails_helper"

describe "the games listing", type: :request do
  def running_game(name)
    game = create_game(:is_draft => false, :name => name, :max_team_number => 20)
    game.update_column(:starts_at, 2.hours.ago)
    game
  end

  it "shows a scheduled game's start time and registration count, and no duration" do
    game = create_game(:is_draft => false, :name => "Скоро", :max_team_number => 20)
    2.times { GameEntry.create!(:game => game, :team => create_team, :status => "accepted") }

    get games_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Скоро")
    expect(response.body).to include(I18n.t("games.list.status_scheduled"))
    expect(response.body).to include("2 / 20")
  end

  it "counts only accepted entries towards registration" do
    game = create_game(:is_draft => false, :max_team_number => 20)
    GameEntry.create!(:game => game, :team => create_team, :status => "accepted")
    GameEntry.create!(:game => game, :team => create_team, :status => "new")
    GameEntry.create!(:game => game, :team => create_team, :status => "rejected")

    get games_path

    expect(response.body).to include("1 / 20")
  end

  it "shows a running game as running, with the teams actually playing" do
    game = running_game("Идёт")
    create_game_passing(:level => create_level(:game => game), :game => game)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_running"))
    expect(response.body).to include(I18n.t("games.list.playing", :count => 1))
  end

  it "marks a paused game as paused without changing its status" do
    game = running_game("Пауза")
    game.pause!

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_running"))
    expect(response.body).to include(I18n.t("games.list.paused"))
  end

  it "shows a finished game's end time and how long it ran" do
    game = running_game("Всё")
    game.update_column(:author_finished_at, game.starts_at + 3725)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_finished"))
    expect(response.body).to include(I18n.t("games.list.duration", :hours => 1, :minutes => 2))
  end

  it "shows no duration for a game with no start time" do
    game = create_game(:is_draft => false, :name => "Без даты")
    game.update_column(:starts_at, nil)

    get games_path

    expect(response.body).to include("Без даты")
    expect(response.body).not_to include(I18n.t("games.list.duration", :hours => 0, :minutes => 0))
  end

  # Two N+1s reached review on the quiz branch this session: one from a
  # missing preload, one from calling a scope on an already-preloaded
  # association, which re-queries. This pins the fix rather than trusting it.
  # Defined at describe level, not inside the example: `def` inside a block
  # takes its default definee from the enclosing class, so it would silently
  # attach to the example group and work only by accident.
  def count_queries
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  it "issues the same number of queries for ten games as for one" do
    running_game("Одна")
    get games_path
    one = count_queries { get games_path }

    9.times { |i| running_game("Игра #{i}") }
    ten = count_queries { get games_path }

    expect(ten).to eq(one)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bundle exec rspec spec/requests/games_listing_spec.rb
```

Expected: failures on missing locale keys (`translation missing: ru.games.list.status_scheduled`) and on the absent counts.

- [ ] **Step 3: Add the locale keys**

Under a new `games.list` section — note `games.list.view`, `.stats`, `.live_channel`, `.full_log`, `.end_game`, `.author_finished` already exist there and must be left untouched.

**Status labels are copied verbatim from `admin.games.index`**, in every locale. The listing gets its own keys — reaching across namespaces would couple two screens that should be free to word things differently — but the *values* must match, or the two screens would show the same state under two different words and defeat the point of Task 1.

`config/locales/ru.yml`:

```yaml
      status: "Статус"
      starts_at: "Начало"
      ends_at: "Окончание"
      participants: "Команды"
      status_withdrawn: "Снята с публикации"
      status_draft: "Черновик"
      status_finished: "Завершена"
      status_running: "Идёт"
      status_scheduled: "Запланирована"
      paused: "на паузе"
      duration: "%{hours} ч %{minutes} мин"
      playing: "играют: %{count}"
      played: "играли: %{count}"
```

`config/locales/en.yml`:

```yaml
      status: "Status"
      starts_at: "Start"
      ends_at: "End"
      participants: "Teams"
      status_withdrawn: "Withdrawn"
      status_draft: "Draft"
      status_finished: "Finished"
      status_running: "Running"
      status_scheduled: "Scheduled"
      paused: "paused"
      duration: "%{hours}h %{minutes}m"
      playing: "playing: %{count}"
      played: "played: %{count}"
```

`config/locales/uk.yml`:

```yaml
      status: "Статус"
      starts_at: "Початок"
      ends_at: "Завершення"
      participants: "Команди"
      status_withdrawn: "Знята з публікації"
      status_draft: "Чернетка"
      status_finished: "Завершена"
      status_running: "Триває"
      status_scheduled: "Запланована"
      paused: "на паузі"
      duration: "%{hours} год %{minutes} хв"
      playing: "грають: %{count}"
      played: "грали: %{count}"
```

`config/locales/ka.yml`:

```yaml
      status: "სტატუსი"
      starts_at: "დაწყება"
      ends_at: "დასრულება"
      participants: "გუნდები"
      status_withdrawn: "მოხსნილია გამოქვეყნებიდან"
      status_draft: "მონახაზი"
      status_finished: "დასრულებული"
      status_running: "მიმდინარე"
      status_scheduled: "დაგეგმილი"
      paused: "შეჩერებულია"
      duration: "%{hours} სთ %{minutes} წთ"
      playing: "თამაშობს: %{count}"
      played: "თამაშობდა: %{count}"
```

- [ ] **Step 4: Create the helper**

Create `app/helpers/games_helper.rb`:

```ruby
# -*- encoding : utf-8 -*-
module GamesHelper
  # Team counts for a whole listing in two queries, regardless of how many
  # games it holds.
  #
  # This lives in a helper rather than in GamesController#index because
  # games/_list is rendered from TWO places -- games/index.html.erb and
  # dashboard/_my_games.html.erb -- and a controller-assigned variable would
  # be nil on the dashboard.
  #
  # Memoised per request on the exact set of ids, so a page rendering the
  # partial twice with different collections still gets one query pair each
  # and no stale reuse.
  def game_team_counts(games)
    ids = games.map(&:id).sort
    @game_team_counts ||= {}
    @game_team_counts[ids] ||= {
      # Deliberately NOT game.game_entries.with_status("accepted").count --
      # with_status is a scope, and a scope builds a new relation, so it
      # re-queries even when the association is already loaded. That exact
      # mistake shipped to review on the quiz branch.
      :registered => GameEntry.where(:game_id => ids, :status => "accepted").group(:game_id).count,
      :playing    => GamePassing.where(:game_id => ids).group(:game_id).count
    }
  end

  # The status tag. Withdrawn is the only danger state; running is the only
  # live one. Pausing is appended, never substituted -- a paused game is still
  # running, and Game#status deliberately does not encode pausing.
  def game_status_tag(game)
    modifier = case game.status
               when :withdrawn then " tag--danger"
               when :running   then " tag--live"
               else                 ""
               end

    tag = content_tag(:span, t("games.list.status_#{game.status}"), :class => "tag#{modifier}")
    tag += " ".html_safe + content_tag(:em, t("games.list.paused")) if game.paused?
    tag
  end

  # How long a finished game ran, or how long a running one has been going.
  # nil when there is nothing meaningful to say -- starts_at is nullable, and
  # "0 ч 0 мин" for a game that has not started would be a lie dressed as data.
  def game_duration_text(game)
    return nil if game.starts_at.nil?

    finish = case game.status
             when :finished then game.author_finished_at
             when :running  then game.paused_at || Time.now
             end
    return nil if finish.nil?

    hours, minutes = hours_and_minutes(finish - game.starts_at)
    t("games.list.duration", :hours => hours, :minutes => minutes)
  end
end
```

- [ ] **Step 5: Rewrite the partial**

Replace `app/views/games/_list.html.erb` entirely:

```erb
<%# Rendered from games/index.html.erb and dashboard/_my_games.html.erb.
    Counts come from a helper rather than a controller ivar for that reason.

    .table--cards collapses to stacked cards below 48rem, using each cell's
    data-label to keep the column name; .table-wrap contains a long game name
    rather than letting it scroll the whole page sideways. %>
<% counts = game_team_counts(games) %>

<div class="table-wrap">
<%# Deliberately NOT class="game-list". That class is used by nine other views
    (levels/_list, hints/_list, games/_teams, games/_game_entries,
    dashboard/_coming_games, dashboard/_finished_games, team_room/index,
    admin/users/show, layouts/_left_menu) and its only rules are
    `.game-list li` (screens.css:17) and `#drawer .game-list a`
    (layout.css:47) -- descendant selectors for <ul> markup that a <table>
    has no children to match. Carrying the class here would style nothing and
    mislead the next person into thinking it does. %>
<table class="table--cards">
  <thead>
    <tr>
      <th><%= t("games.list.name") %></th>
      <th><%= t("games.list.status") %></th>
      <th><%= t("games.list.starts_at") %></th>
      <th><%= t("games.list.ends_at") %></th>
      <th><%= t("games.list.participants") %></th>
      <th></th>
    </tr>
  </thead>
  <tbody>
  <% games.each do |game| %>
    <tr>
      <td data-label="<%= t("games.list.name") %>">
        <strong><%= link_to game.name, game_path(game) %></strong>
      </td>
      <td data-label="<%= t("games.list.status") %>"><%= game_status_tag(game) %></td>
      <td data-label="<%= t("games.list.starts_at") %>">
        <%= l(game.starts_at, :format => :long) if game.starts_at %>
      </td>
      <td data-label="<%= t("games.list.ends_at") %>">
        <% if game.status == :finished && game.author_finished_at %>
          <%= l(game.author_finished_at, :format => :long) %><br>
        <% end %>
        <%= game_duration_text(game) %>
      </td>
      <td data-label="<%= t("games.list.participants") %>">
        <%= counts[:registered].fetch(game.id, 0) %> / <%= game.max_team_number %>
        <% playing = counts[:playing].fetch(game.id, 0) %>
        <% if playing > 0 %>
          &middot;
          <%= game.status == :finished ? t("games.list.played", :count => playing)
                                       : t("games.list.playing", :count => playing) %>
        <% end %>
      </td>
      <%# Every link below keeps its exact text, order and visibility
          condition: features/games/confirmed-teams-preview.feature,
          features/logs/live-channel.feature and features/logs/log.feature all
          reach this listing and click through by link text. New information
          is added AROUND these, never in place of them. %>
      <td>
        <em><%= link_to t("games.list.view"), game_path(game) %></em>
        <% if logged_in? and current_user.author_of?(game) %>
            <em><%= link_to t("shared.edit_short"), edit_game_path(game) %></em>
            <em><%= link_to t("games.list.stats"), game_stats_path(game) if game.started? %></em>
            <em><%= link_to t("games.list.live_channel"), show_live_channel_path(game.id) if game.started? %></em>
            <em><%= link_to t("games.list.full_log"), show_full_log_path(game.id) if game.started? %></em>
            <b><%= link_to t("games.list.end_game"), "/games/end_game/#{game.id}" if (game.started? and !game.author_finished?) %></b>
            <em><%= t("games.list.author_finished") if (game.started? and game.author_finished?) %></em>
        <% end %>
      </td>
    </tr>
  <% end %>
  </tbody>
</table>
</div>
```

Add the one missing header key to all four locales under `games.list`: `name:` — ru `"Игра"`, en `"Game"`, uk `"Гра"`, ka `"თამაში"`.

- [ ] **Step 6: Confirm no CSS change is needed**

No stylesheet edit is required for this task, and none should be made. Verify that:

```bash
grep -rn "game-list" public/stylesheets/
```

returns only `screens.css:17` (`.game-list li`), `screens.css:21` (`.game-list li:last-child`) and `layout.css:47` (`#drawer .game-list a`) — all descendant selectors for `<ul>` markup, all still serving the nine other views that use the class on real lists. The new table does not carry the class, so nothing to rescope.

`.table--cards` (`components.css:92-113`) and `.table-wrap` already supply everything this table needs, including the below-48rem collapse that reads each cell's `data-label`.

If you find yourself wanting to add a CSS rule here, stop and say why in your report rather than adding one — this listing is meant to reuse existing components, and a new rule is a signal that something else is wrong.

- [ ] **Step 7: Run everything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/games_listing_spec.rb
bundle exec rspec spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new spec passes (8 examples); `i18n_spec` passes; the full suite is
**783 + 8 = 791 examples, 0 failures, 6 pending**; cucumber is **234 scenarios (2 undefined) / 2362 steps**.
Report the actual numbers.

**If cucumber fails**, the cause is almost certainly one of the three feature files that click through this listing by link text. Do **not** edit the feature — read the failure, find which `click_link` became ambiguous or unreachable, and fix the partial. `Все игры домена` reaches the page; the failures will name the link inside it.

- [ ] **Step 8: Look at it in a browser**

The suite runs on `rack_test`, which executes no JavaScript and computes no CSS — it is structurally blind to layout. Every UI defect on the last two branches was invisible to it.

```bash
bin/rails server
```

Check `/games` at **390px** and **1280px**, in both light and dark themes, with at least one game in each of scheduled / running / finished state:

- the table collapses to stacked cards below 48rem, each cell showing its `data-label`;
- no horizontal scrolling of the page body at 390px;
- the status tags are legible in both themes;
- a long game name does not push the layout sideways.

Report the actual measurements. If you cannot run a browser, say so plainly rather than implying you looked.

- [ ] **Step 9: Commit**

```bash
git add app/helpers/games_helper.rb app/views/games/_list.html.erb \
        config/locales spec/requests/games_listing_spec.rb
git commit -m "Show status, start, end and team counts on the games listing

The listing was a name and a row of links. It now shows each game's status,
start time, end time with duration, and both team counts -- registered
against capacity, and how many are actually playing.

Counts load in two queries via a helper rather than a controller ivar,
because games/_list is rendered from the dashboard as well as from
GamesController#index. A query-count spec pins that: two N+1s reached review
on the quiz branch, one of them from calling a scope on an already-preloaded
association, which re-queries.

Status labels are copied verbatim from the admin console's, so the two
screens never show the same state under two different words. Every existing
link keeps its text, order and visibility -- three frozen feature files click
through this listing."
```

---

### Task 4: The countdown over-reports by about a day

**Files:**
- Modify: `app/views/shared/_countdown.html.erb:60-88` (`timeDifference` only)
- Test: `spec/views/countdown_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. This task is self-contained and unrelated to Tasks 1-3; it was added mid-run at the repository owner's request after being reported from production.

**The bug, reported live.** With the clock at `2026-08-06 23:13` and a game starting `2026-08-07 22:00` — a real gap of **22h 47m** — the page rendered **"До начала осталось: 1 день 22 часа 46 минут 50 секунд"**, roughly 24 hours too many.

Two defects, stacked, in `timeDifference`:

```js
days   = end.getDate()  - begin.getDate(),   // a CALENDAR day-of-month difference
hms    = (end / 1000 - begin / 1000) % 86400,
hours   = Math.floor(hms/3600) % 60,          // and this should be % 24
```

`days` counts how many times the **date rolls over**; `hours`/`minutes`/`seconds` come from `hms`, the **true remaining interval** reduced mod one day. The two are computed from different things and then printed together, so they double-count: `7 - 6 = 1` day, plus an independently-correct `22:46:50`.

The `% 60` on `hours` is a second bug that cannot currently fire — `hms` is already mod-86400 so `Math.floor(hms/3600)` never exceeds 23 — but it is wrong and shows the same confusion.

**Not related to the epoch fix in PR #22.** That corrected *which instant* the countdown counts to. This is how the interval to that instant is decomposed.

**The binding constraint.** `features/games/enter-game-before-start.feature:23` and `:42` assert the whole year/month/day plural table, and those strings live inside this partial's inline `<script>` (`features/steps/result_steps.rb` uses `have_text(:all, ...)`, which reaches into script tags — there is a comment there explaining exactly this). **The `countdown_settings.lang` object must keep rendering all six keys.** Only the arithmetic may change.

- [ ] **Step 1: Write the failing spec**

Create `spec/views/countdown_spec.rb`:

```ruby
require "rails_helper"

# The countdown is JavaScript, so this asserts on the emitted source rather than
# on a rendered number: the arithmetic that was wrong is right here in the
# template, and the frozen features that touch this partial assert the plural
# table's presence in that same source.
RSpec.describe "shared/_countdown", type: :view do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }

  before do
    assign(:game, game)
    assign(:team, nil)
    assign(:current_user, author)
    view.define_singleton_method(:current_user) { author }
    view.define_singleton_method(:logged_in?)   { true }
  end

  # THE bug: days came from a calendar date subtraction while hours/minutes/
  # seconds came from the true interval, so "1 day" and "22 hours" were counted
  # from different things and printed together.
  it "derives every component from the interval, not from calendar fields" do
    render :partial => "shared/countdown"

    expect(rendered).not_to include("end.getDate()")
    expect(rendered).not_to include("end.getMonth()")
    expect(rendered).not_to include("end.getYear()")
  end

  it "reduces hours modulo 24, not 60" do
    render :partial => "shared/countdown"

    expect(rendered).not_to match(%r{hours\s*=\s*Math\.floor\([^)]*\)\s*%\s*60})
  end

  # features/games/enter-game-before-start.feature:23,42 assert this whole table
  # via have_text(:all, ...), which reaches inside the <script>. It must keep
  # rendering even though years and months are no longer computed.
  it "still renders the full plural table the frozen features assert" do
    render :partial => "shared/countdown"

    %w[years months days hours minutes seconds].each do |unit|
      expect(rendered).to include("#{unit}:")
    end
    expect(rendered).to include(I18n.t("shared.countdown.years").first)
    expect(rendered).to include(I18n.t("shared.countdown.months").first)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/views/countdown_spec.rb
```

Expected: the first two fail — the template still contains `end.getDate()` and the `% 60`. The third should already pass; if it does not, the partial is not rendering as assumed and you should report that before changing anything.

- [ ] **Step 3: Replace the arithmetic**

In `app/views/shared/_countdown.html.erb`, replace the whole `var timeDifference = function(begin, end) { ... };` body down to and including the `if (months < 0) { ... }` block, leaving the `var diff = {...}` line and everything after it intact:

```js
    var timeDifference = function(begin, end) {
      if (end < begin) {
        return false;
      }
      // Every component is derived from the SAME interval. The previous version
      // took days from a calendar day-of-month subtraction (end.getDate() -
      // begin.getDate()) while taking hours/minutes/seconds from the elapsed
      // seconds -- two different measurements printed together, so a gap of
      // 22h47m rendered as "1 day 22 hours 46 minutes": the date rolled over
      // once AND the remainder was nearly a full day.
      //
      // years and months are no longer computed. Calendar months have no fixed
      // length, so mixing them with an interval either approximates (30-day
      // months) or double-counts again; a countdown in days is exact and is
      // what this product needs. They stay in countdown_settings.lang above
      // because features/games/enter-game-before-start.feature:23,42 assert
      // that whole plural table, and the loop below skips any zero value, so
      // they simply never render.
      var total   = Math.floor((end - begin) / 1000),
          years   = 0,
          months  = 0,
          days    = Math.floor(total / 86400),
          hours   = Math.floor(total / 3600) % 24,
          minutes = Math.floor(total / 60) % 60,
          seconds = total % 60;
```

Leave `var diff = {years: years, months: months, days: days, hours: hours, minutes: minutes, seconds: seconds};` and the loop below it exactly as they are — that loop's `if(!diff[i]) continue;` is what makes the zeroed years and months disappear from the output.

- [ ] **Step 4: Run the spec**

```bash
bundle exec rspec spec/views/countdown_spec.rb
```

Expected: PASS, 3 examples.

- [ ] **Step 5: Check the arithmetic against the reported case**

Verify by hand, and put the numbers in your report. For `begin = 2026-08-06 23:13:10` and `end = 2026-08-07 22:00:00`:

- `total` = 82,010 s
- `days` = `floor(82010 / 86400)` = **0**
- `hours` = `floor(82010 / 3600) % 24` = 22
- `minutes` = `floor(82010 / 60) % 60` = 46
- `seconds` = 82,010 % 60 = 50

Rendered: **"22 часа 46 минут 50 секунд"** — no phantom day. Confirm this with `node -e` or equivalent rather than asserting it from reading.

- [ ] **Step 6: Run everything**

```bash
bundle exec rspec
bundle exec cucumber
```

Expected: the full suite is the previous total plus 3, 0 failures, 6 pending; cucumber is **234 scenarios (2 undefined) / 2362 steps**.

**`features/games/enter-game-before-start.feature` is the one to watch** — it asserts the plural table inside this partial's script. If it fails, the `lang` object stopped rendering; restore it rather than editing the feature.

- [ ] **Step 7: Commit**

```bash
git add app/views/shared/_countdown.html.erb spec/views/countdown_spec.rb
git commit -m "Fix the countdown over-reporting by about a day

timeDifference took days from a calendar day-of-month subtraction while taking
hours, minutes and seconds from the elapsed interval -- two different
measurements printed together. A real gap of 22h47m rendered as \"1 day 22
hours 46 minutes\": the date had rolled over once, and the remainder was
independently almost a full day.

Every component now comes from the same interval. hours also reduced modulo 24
rather than 60, which was wrong but could not fire while hms was already
reduced modulo one day.

years and months are no longer computed -- calendar months have no fixed
length, so mixing them with an interval either approximates or double-counts
again. They stay in the lang table, which enter-game-before-start.feature
asserts, and the render loop skips zero values so they never appear."
```

---

## Definition of done

- `bundle exec rspec` — 794 examples, 0 failures, 6 pending (762 baseline + 29 from Tasks 1-3 + 3 from Task 4).
- `bundle exec cucumber` — 234 scenarios (2 undefined), 2362 steps, **with no feature file modified**.
- `bin/rails zeitwerk:check` — `All is good!`.
- `git diff --stat master -- features/` is empty.
- `/games` renders status, start, end and participant counts, verified in a browser at 390px and 1280px in both themes.
- The admin games index still labels every game exactly as before, now via `Game#status`.
- The countdown on a game page agrees with the start time printed above it, with no phantom extra day.
