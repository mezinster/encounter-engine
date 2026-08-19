# A Paid Game's Ending Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A team that finishes a paid game sees their result instead of an access error, and a revoked pass actually stops play.

**Architecture:** `GamePassingsController#gated_passing` becomes an explicit answer to "what is this
team's state?" rather than a lookup that raises when it fails — serving a finished attempt read-only
when no pass remains. A new filter renders a distinct message for a revoked pass, mirroring the
withdrawn-game notice. Then the finished gated attempt gets a screen of its own.

**Tech Stack:** Rails 8.0, Ruby 3.3.12, SQLite in dev/test and PostgreSQL in production, RSpec,
Cucumber (Russian Gherkin), seven locales.

**Spec:** `docs/superpowers/specs/2026-08-19-gated-finish-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Every session starts with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Hash rockets** (`:key => value`) in application code; match the surrounding file.
- **Never edit any `features/**/*.feature` file** — a byte-identical acceptance contract of
  **228 scenarios / 2325 steps**.
- **All seven locales** for every new key: `ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`.
  `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity and only a **subset** check for the other five.
  `spec/i18n_play_screen_spec.rb` pins the strings a team reads under time pressure — the finish
  screen belongs on its list.
- **No schema change.** This sub-project adds no columns and no migration.
- **`AccessPass#spent?` must not change.** It is deliberately `attempt.finished_at.present?`, its
  comment records that this is "today's ENCODING of the rule, not the rule itself", and
  `spec/models/access_pass/spent_spec.rb` asserts every state. Revocation is a separate axis.
- **No Turbo and no rails-ujs.** Nothing may depend on JavaScript to function.
- **`create_user` takes no arguments**; **`create_team(options)` takes `:captain` and `:members`**;
  **`create_game_passing` calls `create_team` with no options, so its team has no captain.**
- **A request spec without `set_game_schedule!` gets 401s** — `starts_at` lives on `game_runs`, not
  `games`, and defaults to 2099. **Every negative assertion needs a positive status assertion beside
  it.** Twelve examples in this programme have passed against broken code or vacuous fixtures.
- **Assert counts across a request** when a fix is about *not* creating something — `GamePassing.count`
  and `AccessPass` state before and after. An example asserting only a status can pass while quietly
  enrolling a team.
- TDD: the failing test first, watch it fail for the stated reason, then implement.

---

## File structure

| File | Responsibility |
|---|---|
| `app/controllers/game_passings_controller.rb` | the state resolution and the revoked filter |
| `app/views/game_passings/pass_revoked.html.erb` | what a revoked team sees |
| `app/views/game_passings/gated_finish.html.erb` | the finish screen |
| `app/views/games/_pass_standings.html.erb` | gains an optional `highlight` local |
| `config/locales/*.yml` | seven files, every new key |

---

## Task 1: What state is this team in?

This task adds **no view for the finish case** and is provable against the spec's six-row table on
its own. It changes a security chokepoint deciding who may play a paid game, which is why it lands
alone.

**Files:**
- Modify: `app/controllers/game_passings_controller.rb` (`#gated_passing`, currently `:671-687`; the `before_action` list around `:44`)
- Create: `app/views/game_passings/pass_revoked.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/gated_finish_spec.rb`

**Interfaces:**
- Produces: `gated_passing` returns a finished attempt when no pass remains; a new
  `before_action :halt_if_pass_revoked` renders `game_passings/pass_revoked`.
- Consumes: `AccessPass#live?` (`!revoked? && !spent?`), `AccessPass#revoked?`,
  `AccessPass.next_for(game, team)`, `GamePassing.gated_attempt_for(game, team)`.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/gated_finish_spec.rb`. One example per row of the spec's §2 table:

```ruby
require "rails_helper"

describe "a paid game's ending", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A gated game with two levels, a team with a captain, and a live pass.
  def gated_setup
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:access_mode => "pass_required")
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    pass    = create_access_pass(:game => game, :team => team)
    [ game.reload, team, captain, one, pass ]
  end

  def finished_attempt(game, team, pass)
    create_game_passing(:game => game, :team => team, :game_run => nil,
                        :access_pass => pass, :level => game.levels.first)
      .tap { |p| p.update!(:finished_at => 1.hour.ago) }
  end

  it "serves a finished attempt instead of refusing it" do
    game, team, captain, _one, pass = gated_setup
    attempt = finished_attempt(game, team, pass)
    sign_in(captain)

    passings_before = GamePassing.count

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok).or have_http_status(:found)
    expect(response.body).not_to include(I18n.t("errors.no_access_pass"))
    # The fix must not enrol them again or consume anything.
    expect(GamePassing.count).to eq(passings_before)
    expect(attempt.reload.finished_at).not_to be_nil
  end

  it "still gives a fresh attempt when another live pass remains" do
    game, team, captain, one, pass = gated_setup
    finished_attempt(game, team, pass)
    create_access_pass(:game => game, :team => team)
    sign_in(captain)

    expect { get show_current_level_path(:game_id => game.id) }
      .to change { GamePassing.count }.by(1)

    fresh = GamePassing.order(:id).last
    expect(fresh.finished_at).to be_nil
    expect(fresh.current_level).to eq(one)
  end

  it "refuses a team that never had a pass" do
    game, _team, _captain, _one, _pass = gated_setup
    stranger = create_user
    create_team(:captain => stranger)
    sign_in(stranger)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
    expect(GamePassing.count).to eq(0)
  end

  describe "a revoked pass" do
    it "stops a team already playing, without advancing anything" do
      game, team, captain, one, pass = gated_setup
      attempt = create_game_passing(:game => game, :team => team, :game_run => nil,
                                    :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      sign_in(captain)

      post post_answer_path(:game_id => game.id), :params => { :answer => "anything" }

      expect(attempt.reload.current_level).to eq(one)
      expect(attempt.finished_at).to be_nil
    end

    it "shows its own message, not the stranger's error" do
      game, team, captain, one, pass = gated_setup
      create_game_passing(:game => game, :team => team, :game_run => nil,
                          :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("errors.access_revoked"))
      expect(response.body).not_to include(I18n.t("errors.no_access_pass"))
    end

    it "still lets a team with a replacement pass play" do
      game, team, captain, one, pass = gated_setup
      create_game_passing(:game => game, :team => team, :game_run => nil,
                          :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      create_access_pass(:game => game, :team => team)
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("errors.access_revoked"))
    end
  end
end
```

`create_access_pass(options)` takes `:game` and `:team` and defaults `:source` to
`"operator_invite"` (`spec/spec_helpers/fixtures_helper.rb:169`). Note its default game is built with
`:is_draft => false` — pass your own game, as the helper above does.

- [ ] **Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/requests/gated_finish_spec.rb`
Expected: the finished-attempt example fails with the page containing `errors.no_access_pass`, and
the revoked examples fail with a missing `errors.access_revoked` translation.

- [ ] **Step 3: Replace `gated_passing`**

In `app/controllers/game_passings_controller.rb`, replace the body (`:671-687`), keeping the existing
comment about `gated_attempt_for` being the single definition of "this team's current attempt":

```ruby
  def gated_passing
    raise Authentication::Unauthorized, t("errors.no_access_pass") if @team.nil?

    # GamePassing.gated_attempt_for is THE single definition of "this team's
    # current attempt" -- newest first, which is provably the live one whenever
    # a live one exists.
    attempt = GamePassing.gated_attempt_for(@game, @team)

    # live?, not !spent?. spent? is finished_at.present? and says NOTHING about
    # revocation, so an attempt whose pass an operator had revoked was served
    # and the team played on -- revocation was honoured only by
    # AccessPass.next_for, which decides who may START and is consulted only
    # when there is no attempt to serve.
    return attempt if attempt && attempt.access_pass.live?

    # A replacement pass wins over a finished attempt: a team who bought
    # another go gets one rather than being handed the old result.
    pass = AccessPass.next_for(@game, @team)
    return build_gated_attempt(pass) if pass

    # Nothing left to play. A FINISHED attempt is served read-only rather than
    # refused: the code used to treat "your attempt is finished" as "you have
    # no attempt", which handed a paying customer who completed the game the
    # message written for a stranger who never bought anything.
    return attempt if attempt&.finished?

    raise Authentication::Unauthorized, t("errors.no_access_pass")
  end

  def build_gated_attempt(pass)
    GamePassing.create!(:team => @team, :game => @game,
                        :game_run => nil, :access_pass => pass,
                        :current_level => @game.levels.first)
  end
```

- [ ] **Step 4: Add the revoked filter**

In the `before_action` list, immediately **after** `halt_if_withdrawn` (currently `:44`):

```ruby
  before_action :halt_if_pass_revoked, except: [ :index, :show_results ]
```

and beside `halt_if_withdrawn` in the same private section:

```ruby
  # Rendered rather than raised, for the reason the withdrawn notice above is:
  # a bare 401 says "you are not authorised", which is true here and useless --
  # it does not say WHAT CHANGED or what to do. The stranger's message is
  # actively wrong for this team: they did have access, and telling them to ask
  # the organiser about access the organiser deliberately took away is a
  # runaround.
  #
  # Only when NO live pass remains. A team whose pass was revoked but who holds
  # a replacement plays on -- that is the same rule that gives a finished team
  # with a spare pass a fresh attempt.
  def halt_if_pass_revoked
    return unless @game.pass_required?
    return if @team.nil?
    return if AccessPass.next_for(@game, @team).present?
    return unless AccessPass.where(:game_id => @game.id, :team_id => @team.id)
                            .where.not(:revoked_at => nil).exists?

    if request.get?
      render "game_passings/pass_revoked"
    else
      redirect_to show_current_level_path(:game_id => @game.id)
    end
  end
```

**This filter must sit before `find_or_create_game_passing`**, exactly as `halt_if_withdrawn` does
and for the same reason: that filter *creates* a passing when the team has none, so halting after it
would enrol a revoked team merely for reading the message. Check the position of
`find_or_create_game_passing` in the list and place accordingly.

- [ ] **Step 5: Write the revoked view**

Create `app/views/game_passings/pass_revoked.html.erb`:

```erb
<div class="page">
  <h2><%= t("errors.access_revoked") %></h2>
  <p><%= t("game_passings.pass_revoked.what_to_do") %></p>
  <p><%= link_to @game.name, game_path(@game) %></p>
</div>
```

The game's own name is safe to render here: this is the team's own paid game, which they are plainly
entitled to see, and `GamesController#show` has no pass gate.

- [ ] **Step 6: Add the locale keys**

Under `errors:`, beside `no_access_pass`:

| locale | `access_revoked` |
|---|---|
| ru | `Доступ к этой игре отозван` |
| en | `Access to this game has been withdrawn` |
| uk | `Доступ до цієї гри відкликано` |
| be | `Доступ да гэтай гульні адкліканы` |
| pl | `Dostęp do tej gry został cofnięty` |
| tr | `Bu oyuna erişim geri alındı` |
| ka | `ამ თამაშზე წვდომა გაუქმებულია` |

Under `game_passings:`, a new `pass_revoked:` block:

| locale | `what_to_do` |
|---|---|
| ru | `Свяжитесь с организатором игры.` |
| en | `Please contact the game's organiser.` |
| uk | `Зверніться до організатора гри.` |
| be | `Звярніцеся да арганізатара гульні.` |
| pl | `Skontaktuj się z organizatorem gry.` |
| tr | `Oyunun düzenleyicisiyle iletişime geçin.` |
| ka | `დაუკავშირდით თამაშის ორგანიზატორს.` |

- [ ] **Step 7: Run the tests**

Run: `bundle exec rspec spec/requests/gated_finish_spec.rb spec/requests/gated_play_spec.rb spec/models/access_pass spec/i18n_spec.rb`
Expected: PASS. `spec/models/access_pass` is in the command because `spent?` must be untouched, and
`gated_play_spec.rb` because it exercises the method this task rewrites.

- [ ] **Step 8: Prove the two branches are load-bearing**

Two mutations, both pasted into the report:

- change `attempt.access_pass.live?` back to `!attempt.access_pass.spent?` — the **"stops a team
  already playing"** example must go RED.
- delete the `return attempt if attempt&.finished?` line — the **"serves a finished attempt"**
  example must go RED.

Restore each and confirm GREEN.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/game_passings_controller.rb \
        app/views/game_passings/pass_revoked.html.erb \
        config/locales spec/requests/gated_finish_spec.rb
git commit -m "Answer what state a gated team is in, not just which attempt to play"
```

---

## Task 2: The finish screen

**Files:**
- Modify: `app/controllers/game_passings_controller.rb` (`#render_finished_passing`, currently `:309-314`)
- Create: `app/views/game_passings/gated_finish.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Modify: `spec/i18n_play_screen_spec.rb` (`PLAY_SCREEN_KEYS`)
- Test: `spec/requests/gated_finish_spec.rb` (the file Task 1 created)

**Interfaces:**
- Consumes: `gated_passing` serving a finished attempt (Task 1); `Game#pass_standings` →
  completed attempts sorted by `duration`; `GamePassing#duration` → Integer seconds;
  `GamePassing#seconds_to_hms(seconds)` → String; `Team#balance`;
  `GamePassing#point_transactions`.

`render_finished_passing` currently redirects a gated game to `game_path`. That redirect is what this
task replaces — and the spec explains why the game page is not enough: `_pass_standings` is a
**league table** with no indication which row is the team's own and nothing about points.

- [ ] **Step 1: Write the failing test**

Add to `spec/requests/gated_finish_spec.rb`:

```ruby
  describe "the finish screen" do
    def scored_gated_setup
      captain = create_user
      team    = create_team(:captain => captain)
      game    = create_game(:access_mode => "pass_required", :points_enabled => true,
                            :level_completion_points => 10, :game_completion_points => 50)
      one     = create_level(:game => game, :position => 1)
      create_level(:game => game, :position => 2)
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      pass    = create_access_pass(:game => game, :team => team)
      [ game.reload, team, captain, one, pass ]
    end

    it "shows their time, their place and their points" do
      game, team, captain, one, pass = scored_gated_setup
      attempt = create_game_passing(:game => game, :team => team, :game_run => nil,
                                    :access_pass => pass, :level => one)
      attempt.update!(:finished_at => 1.hour.ago)
      PointTransaction.award!(:passing => attempt, :reason => "game_completed",
                              :level => nil, :amount => 50)
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(attempt.seconds_to_hms(attempt.duration))
      expect(response.body).to include("50")
      expect(response.body).to include(I18n.t("game_passings.gated_finish.your_place"))
    end

    # A skip fine is negative and this is the screen where a team finds out
    # what skipping cost them.
    it "shows a negative row in their own ledger" do
      game, team, captain, one, pass = scored_gated_setup
      attempt = create_game_passing(:game => game, :team => team, :game_run => nil,
                                    :access_pass => pass, :level => one)
      attempt.update!(:finished_at => 1.hour.ago)
      PointTransaction.award!(:passing => attempt, :reason => "level_skipped",
                              :level => one, :amount => -25)
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("-25")
    end

    # Points are off for most games. The screen must still be coherent.
    it "is coherent for a game with no points enabled" do
      captain = create_user
      team    = create_team(:captain => captain)
      game    = create_game(:access_mode => "pass_required")
      one     = create_level(:game => game, :position => 1)
      create_level(:game => game, :position => 2)
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      pass    = create_access_pass(:game => game, :team => team)
      attempt = create_game_passing(:game => game.reload, :team => team, :game_run => nil,
                                    :access_pass => pass, :level => one)
      attempt.update!(:finished_at => 1.hour.ago)
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(attempt.seconds_to_hms(attempt.duration))
      expect(response.body).not_to include("translation missing")
    end
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/requests/gated_finish_spec.rb`
Expected: the three new examples fail — the response is a 302 to the game page, so none of the
expected strings is present.

- [ ] **Step 3: Render the screen instead of redirecting**

Replace `render_finished_passing` (`:309-314`), keeping the comment above it about `#show_results`:

```ruby
  def render_finished_passing
    if @game.pass_required?
      @standings = @game.pass_standings
      @place     = @standings.index(@game_passing)&.+(1)
      @ledger    = @game_passing.point_transactions.includes(:level).order(:created_at)
      return render "game_passings/gated_finish"
    end

    @run ||= @game.current_run
    render :show_results
  end
```

`@standings.index(@game_passing)` compares by identity through ActiveRecord's `==`, which is id
equality for persisted records — `pass_standings` loads its own objects, so this must not be `equal?`.
`&.+(1)` leaves `@place` nil when the attempt is somehow absent from the standings, which the view
handles rather than raising.

- [ ] **Step 4: Write the view**

Create `app/views/game_passings/gated_finish.html.erb`:

```erb
<div class="page">
  <h2><%= t("game_passings.gated_finish.title") %></h2>

  <p><%= t("game_passings.gated_finish.your_place") %>:
     <%= @place || t("game_passings.gated_finish.unplaced") %></p>
  <p><%= t("game_passings.gated_finish.your_time") %>:
     <%= @game_passing.seconds_to_hms(@game_passing.duration) %></p>

  <% if @ledger.any? %>
    <h3><%= t("game_passings.gated_finish.your_points") %></h3>
    <div class="table-wrap">
      <table class="table--cards">
        <tbody>
          <% @ledger.each do |row| %>
            <tr>
              <td data-label="<%= t("teams.show.reason") %>">
                <%= PointTransaction::REASONS.include?(row.reason) ? t("teams.show.reasons.#{row.reason}") : row.reason %>
              </td>
              <td data-label="<%= t("teams.show.amount") %>"><%= row.amount %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    <p><%= t("game_passings.gated_finish.balance") %>: <%= @game_passing.team.balance %></p>
  <% end %>

  <%= render "games/pass_standings", game: @game %>

  <p><%= link_to @game.name, game_path(@game) %></p>
</div>
```

The reason label is rendered from `PointTransaction::REASONS` with a fallback to the raw value,
copying `teams/show.html.erb` — an unrecognised reason must not print `translation missing:` onto a
page a customer reads. Reusing `teams.show.reasons.*` rather than duplicating seven locales' worth of
labels is deliberate: two copies would drift.

- [ ] **Step 4b: Mark the team's own row in the standings**

Spec §3.1 requires the team's own attempt to be marked, so a team scanning the table can find
themselves without reading every row. `app/views/games/_pass_standings.html.erb` is shared with the
game page, so it gains an optional local rather than a second copy:

```erb
<% highlight = defined?(highlight) ? highlight : nil %>
```

at the top, and on the row:

```erb
        <tr class="<%= "is-you" if highlight && attempt == highlight %>">
```

Then render it from the finish screen with `highlight: @game_passing`. The game page's own
`render "pass_standings", game: @game` passes no `highlight` and is unaffected — `defined?` rather
than `local_assigns[:highlight]` because a partial rendered without a local raises on a bare
reference.

Add a CSS rule for `.is-you` in `public/stylesheets/layout.css` beside the other table rules. Keep it
to a background or weight change: this table is already responsive via `.table--cards`, and anything
that changes the row's box will need re-measuring.

Add an example asserting the class appears on the team's own row and not on another team's — build a
second finished attempt for a different team so the negative half is real rather than vacuous.

- [ ] **Step 5: Add the locale keys**

Under `game_passings:`, a new `gated_finish:` block:

| key | ru | en | uk |
|---|---|---|---|
| `title` | `Игра пройдена` | `Game finished` | `Гру пройдено` |
| `your_place` | `Ваше место` | `Your place` | `Ваше місце` |
| `your_time` | `Ваше время` | `Your time` | `Ваш час` |
| `your_points` | `Ваши очки` | `Your points` | `Ваші очки` |
| `balance` | `Всего у команды` | `Team total` | `Всього в команди` |
| `unplaced` | `не определено` | `not determined` | `не визначено` |

| key | be | pl | tr | ka |
|---|---|---|---|---|
| `title` | `Гульня пройдзена` | `Gra ukończona` | `Oyun tamamlandı` | `თამაში დასრულებულია` |
| `your_place` | `Ваша месца` | `Twoje miejsce` | `Sıralamanız` | `თქვენი ადგილი` |
| `your_time` | `Ваш час` | `Twój czas` | `Süreniz` | `თქვენი დრო` |
| `your_points` | `Вашы ачкі` | `Twoje punkty` | `Puanlarınız` | `თქვენი ქულები` |
| `balance` | `Усяго ў каманды` | `Łącznie drużyna` | `Takım toplamı` | `გუნდის ჯამი` |
| `unplaced` | `не вызначана` | `nieokreślone` | `belirlenmedi` | `არ არის განსაზღვრული` |

- [ ] **Step 6: Add the finish screen to the play-screen key list**

In `spec/i18n_play_screen_spec.rb`, add `game_passings.gated_finish.title` and
`game_passings.gated_finish.your_place` to `PLAY_SCREEN_KEYS`.

That spec exists because a missing key falls back to `ru` and renders the Russian play screen
mid-game to a player who chose another language. The finish screen is the **last thing a paying
customer sees**, which makes it exactly the kind of string it guards.

- [ ] **Step 7: Run the tests**

Run: `bundle exec rspec spec/requests/gated_finish_spec.rb spec/requests/gated_play_spec.rb spec/i18n_spec.rb spec/i18n_play_screen_spec.rb spec/requests/team_history_spec.rb`
Expected: PASS. `team_history_spec.rb` is in the command because this task reuses its reason labels.

- [ ] **Step 8: Measure the play screen**

Run: `bin/measure-play-screen`
Expected: passes at 390×680, 375×553 and 1280×800.

This screen replaces the play screen for a finished gated attempt. Neither suite can see layout —
rack-test parses no stylesheet, so content below the fold is fully "visible" to every assertion
either suite can make, and a broken play screen has shipped that way here before.

**Check the notice's own page does not nest `.page` inside the layout's `.page`.** The withdrawn
notice shipped with that defect and gave 117–169px of dead scroll; the layout already opens `.page`.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/game_passings_controller.rb \
        app/views/game_passings/gated_finish.html.erb \
        app/views/games/_pass_standings.html.erb public/stylesheets/layout.css \
        config/locales spec/i18n_play_screen_spec.rb spec/requests/gated_finish_spec.rb
git commit -m "Give a finished paid game a screen of its own"
```

---

## Gates

The controller runs both full suites, each from its own `bin/rails db:test:prepare` — RSpec and
Cucumber share `db/test.sqlite3`, and rows left by the first run produce phantom failures in the
second.

- After **Task 1**, because it changes a security chokepoint deciding who may play a paid game.
- After **Task 2**.

Expected: RSpec 0 failures with only the 6 pre-existing pending examples; Cucumber **238 scenarios
(2 undefined, 236 passed) / 2386 steps**, unchanged — no `.feature` file is touched.

---

## Deliberately not in this plan

- **Changing what `AccessPass#spent?` means.** Spec §2.
- **A finish screen for non-gated games.** They have `show_results` and a run's finish protocol;
  merging the two is a larger question.
- **Notifying a team that their pass was revoked.** They learn on their next request, as with a
  withdrawn game.
- **Re-opening a finished attempt.** The screen is read-only; replay needs a new pass, which already
  works.
