# Gameplay Access Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make game registration a server-side gate instead of a view-level suggestion, stop the
play controller writing rows before it has authorised the request, and stop the quiz submission
path echoing back the text of options the player never had access to.

**Architecture:** All three defects live in `GamePassingsController`. The registration check goes
into `find_or_create_game_passing` at the point of *creation* rather than into a new `before_action`
— that placement is deliberate and load-bearing: an existing `GamePassing` is served unchanged, so a
team already mid-game is never locked out if their entry status changes underneath them, and the 75
places across the Cucumber suite that reach the create branch keep working. The nil-team guard falls
out of the same method for free, which fixes the orphan-row defect without reordering the filter
chain.

**Tech Stack:** Rails 8.0, RSpec request and controller specs, Cucumber (Russian Gherkin), plain
fixture helpers in `spec/spec_helpers/fixtures_helper.rb`.

## Global Constraints

- Ruby 3.3.12 via rbenv, **not on `PATH` in non-login shells**. Prefix every shell command with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never edit any file under `features/`** ending in `.feature`. Step definitions are editable.
  This plan needs **zero** feature-file and zero step-definition changes — that has been verified
  empirically, see "Verification already done" below.
- Capture a green baseline with `bundle exec rspec` and `bundle exec cucumber` before starting.
- Hash rockets (`:key => value`) throughout, including for symbol keys. Match the surrounding file.
- New i18n keys go into **all four** of `config/locales/{ru,en,uk,ka}.yml`. `spec/i18n_spec.rb`
  enforces exact `ru`↔`en` leaf-key parity. The `uk` and `ka` strings in this plan were machine-
  produced without a native reviewer — that is the existing state of those locales and is
  acceptable, but do not represent them as reviewed.
- Do not introduce FactoryBot. Extend `spec/spec_helpers/fixtures_helper.rb`.

## Verification already done — do not re-litigate

Before this plan was written, the proposed guard was implemented out-of-tree and both suites were
run against it. Recording the result here so the implementer does not have to rediscover it:

- **Cucumber: 234 scenarios, 2358 steps, all passing** with the guard installed. A probe recorded
  75 hits on the create branch across the whole suite; every one was either an accepted entry or a
  testing game. The structural reason is that the only non-testing route to `/play/:id` in the UI is
  `app/views/shared/_current_games_status.html.erb:1-8`, which renders the "Играть!" link *only* for
  `status == "accepted"`.
- **The `is_testing?` exemption is load-bearing.** Removing it fails exactly four scenarios
  (`features/games/test-game-1.feature:50,63,77` and `features/games/test-game-2.feature:21`),
  because author test mode plays with the author's own team, which by construction has no entry.
- **RSpec: 11 examples break** without Task 1's preparation, in three files. Task 1 fixes them
  *before* the guard lands, so no commit is ever red.

---

## File Structure

**Modified:**
- `app/controllers/game_passings_controller.rb:136-146` (`post_options` — Task 3) and `:243-248`
  (`find_or_create_game_passing` — Task 2). No filter-chain reordering.
- `spec/spec_helpers/fixtures_helper.rb` — add `create_game_entry` (Task 1).
- `spec/controllers/game_passings/show_current_level_spec.rb`,
  `spec/controllers/game_passings/post_answer_spec.rb`,
  `spec/requests/translated_level_spec.rb` — register their teams (Task 1).
- `config/locales/{ru,en,uk,ka}.yml` — one new key (Task 2).

**Created:**
- `spec/requests/game_registration_enforcement_spec.rb` (Task 2)
- `spec/requests/quiz_option_scope_spec.rb` (Task 3)

---

### Task 1: Give the specs a registration fixture, before the guard exists

**Files:**
- Modify: `spec/spec_helpers/fixtures_helper.rb` (append after `create_game_passing`, around `:103`)
- Modify: `spec/controllers/game_passings/show_current_level_spec.rb` (the `before :each` of the
  `"when a team member enters game passing"` block covering examples at `:54, :59, :65, :76`)
- Modify: `spec/controllers/game_passings/post_answer_spec.rb` (the `before :each`, covering
  examples at `:28, :32, :42, :46, :56, :60`)
- Modify: `spec/requests/translated_level_spec.rb` (setup covering `:68, :89, :131`)

**Interfaces:**
- Produces: `create_game_entry(options = {})` returning a persisted `GameEntry` with
  `status: "accepted"` by default. Task 2's spec consumes it.

**Why this task is first:** these three files create no `GamePassing` via the fixture helper — they
rely on the controller creating it on first request, with no `GameEntry` anywhere. Adding the entry
now is a no-op against current behaviour (they stay green), and it means the guard in Task 2 can
land without a red commit in between. Two of these examples currently pass *vacuously* and will
start proving something for the first time — see Step 4.

- [ ] **Step 1: Add the fixture helper**

Append to `spec/spec_helpers/fixtures_helper.rb`, after `create_game_passing`:

```ruby
  # A team plays a game only if its entry was accepted -- enforced in
  # GamePassingsController#find_or_create_game_passing. Specs that let the
  # controller create the passing (rather than pre-creating one with
  # create_game_passing) need the entry that authorises it.
  def create_game_entry(options={})
    creation_params = {
      :status => "accepted"
    }.merge(options)

    GameEntry.create! creation_params
  end
```

- [ ] **Step 2: Verify the helper works**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails runner 'puts GameEntry.column_names.inspect'
```

Expected: the output includes `game_id`, `team_id` and `status`. `GameEntry` validates
`game` presence and `team_id` presence (`app/models/game_entry.rb:6-7`), so both must be passed by
callers.

- [ ] **Step 3: Register the teams in the three affected spec files**

In each file, find the setup block that creates the team and add one line after it. The shape is:

```ruby
    create_game_entry(:game => @game, :team => @team)
```

using whatever the local variable names are in that file. Concretely:

- `spec/controllers/game_passings/show_current_level_spec.rb` — in the `before :each` of the
  `"when a team member enters game passing"` describe block, after the team is created.
- `spec/controllers/game_passings/post_answer_spec.rb` — in the `before :each`, after
  `@team = create_team :captain => @team_member`. One line here covers all six examples, including
  the ones that only assert 401.
- `spec/requests/translated_level_spec.rb` — after the team is created and before the first request.

- [ ] **Step 4: Run the three files and confirm they are still green**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/controllers/game_passings/show_current_level_spec.rb \
                  spec/controllers/game_passings/post_answer_spec.rb \
                  spec/requests/translated_level_spec.rb
```

Expected: all green, same counts as your baseline. If anything fails now, the entry is malformed
(most likely a missing `:game` or `:team`) — fix it before continuing.

**Two examples in these files currently pass vacuously.** Confirm they now prove something:

- `spec/requests/translated_level_spec.rb:131` — the N+1 query-count guard. Before registration it
  compared the query counts of two requests that both 401'd, so `expect(large_count).to eq(small_count)`
  held while proving nothing. After Step 3 it exercises real rendering. If it now **fails**, you
  have found a genuine N+1 that was hidden — report it, do not delete the assertion.
- `spec/controllers/game_passings/post_answer_spec.rb:42` — `@answer_was_correct` was `nil` (falsey)
  because the action never ran. It should now assert against a real `false`.

- [ ] **Step 5: Commit**

```bash
git add spec/spec_helpers/fixtures_helper.rb \
        spec/controllers/game_passings/show_current_level_spec.rb \
        spec/controllers/game_passings/post_answer_spec.rb \
        spec/requests/translated_level_spec.rb
git commit -m "Register the teams that the play specs let the controller create passings for

Three spec files reached the create branch of find_or_create_game_passing with
no GameEntry at all. Adding the entry is a no-op today and is the precondition
for enforcing registration server-side. Two examples were passing vacuously
against 401s and now exercise the real path."
```

---

### Task 2: Require an accepted entry before creating a game passing

**Files:**
- Modify: `app/controllers/game_passings_controller.rb:243-248`
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`, `config/locales/uk.yml`,
  `config/locales/ka.yml`
- Test: `spec/requests/game_registration_enforcement_spec.rb` (create)

**Interfaces:**
- Consumes: `create_game_entry` from Task 1; `GameEntry.of(team, game)`
  (`app/models/game_entry.rb:13-15`) which returns the entry or nil; `Authentication::Unauthorized`
  (`app/controllers/concerns/authentication.rb:6`) which `ApplicationController` renders as 401.
- Produces: nothing consumed by later tasks.

**Background:** the filter chain checks authenticated, on *a* team, game started, not author-
finished, not exited, not the author. It never checks that this team was admitted to *this* game.
`ensure_team_member` only asks `current_user.member_of_any_team?`. Registration is enforced only in
`app/views/shared/_current_games_status.html.erb` and `_countdown.html.erb`, which merely hide
links. Separately, `find_team` sets `@team = current_user.team`, which is `nil` for a team-less
user, and `GamePassing` declares `belongs_to :team, optional: true` with a nullable column — so the
create at position 4 of the filter chain commits a `team_id NULL` row before `ensure_team_member`
raises 401 at position 8. That orphan row makes the author's stats page and, after `end_game`, the
**public** results page 500 permanently.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/game_registration_enforcement_spec.rb`:

```ruby
require "rails_helper"

# Registration used to be enforced only in the view layer -- shared/
# _current_games_status.html.erb hides the "Играть!" link unless the entry is
# accepted, but nothing stopped a direct GET. Any user could create a team and
# play any started game, including one whose entry the author had rejected.
describe "playing a game your team is not registered for", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.update_column(:starts_at, 1.hour.ago)
    g
  end
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Self-service: POST /teams needs only a name, and the creator becomes
  # captain. This is the attacker's entire setup cost.
  def player_on_a_fresh_team
    user = create_user
    team = create_team(:captain => user)
    user.update!(:team => team)
    user
  end

  it "refuses a team that never applied" do
    sign_in(player_on_a_fresh_team)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a team whose entry was rejected" do
    player = player_on_a_fresh_team
    create_game_entry(:game => game, :team => player.team, :status => "rejected")
    sign_in(player)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:unauthorized)
  end

  it "admits a team whose entry was accepted" do
    player = player_on_a_fresh_team
    create_game_entry(:game => game, :team => player.team)
    sign_in(player)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.to change { GamePassing.count }.by(1)

    expect(response).to have_http_status(:ok)
  end

  # The orphan-row defect: find_or_create_game_passing ran at filter position 4
  # while ensure_team_member ran at position 8, so a team-less user's 401 still
  # left a GamePassing with team_id NULL. game_passings/index.html.erb:65 and
  # show_results.html.erb:61 both dereference game_passing.team.name, so that
  # row 500'd the author's stats page and -- after end_game -- the public
  # results page, permanently and with no UI able to remove it.
  it "creates nothing for a user who is on no team" do
    sign_in(create_user)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:unauthorized)
  end

  # A team already mid-game must not be locked out if their entry changes
  # underneath them -- the gate is on starting, not on continuing.
  it "keeps serving a passing that already exists" do
    passing = create_game_passing(:level => level)
    player  = create_user
    player.update!(:team => passing.team)
    passing.team.update!(:captain => player)
    sign_in(player)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_registration_enforcement_spec.rb
```

Expected: 5 examples, 3 failures — "refuses a team that never applied", "refuses a team whose entry
was rejected" and "creates nothing for a user who is on no team" all fail because a `GamePassing`
*is* created. The two positive examples already pass.

- [ ] **Step 3: Add the i18n key to all four locales**

Under the existing `errors:` block (the one already holding `not_team_member`, `must_be_captain`,
`must_be_author`), add:

`config/locales/ru.yml`
```yaml
    not_registered_for_game: "Ваша команда не зарегистрирована на эту игру."
```

`config/locales/en.yml`
```yaml
    not_registered_for_game: "Your team is not registered for this game."
```

`config/locales/uk.yml`
```yaml
    not_registered_for_game: "Ваша команда не зареєстрована на цю гру."
```

`config/locales/ka.yml`
```yaml
    not_registered_for_game: "თქვენი გუნდი არ არის რეგისტრირებული ამ თამაშზე."
```

- [ ] **Step 4: Implement the guard**

Replace `app/controllers/game_passings_controller.rb:243-248` with:

```ruby
  # TODO: must be a critical section, double creation is possible!
  #
  # Registration is checked HERE, at creation, and deliberately not in a
  # before_action. Two consequences, both wanted:
  #
  # 1. An existing passing is served unchanged. A team that is already playing
  #    must not be locked out because their entry status changed underneath
  #    them -- the gate is on starting a game, not on continuing one.
  # 2. The nil-team case is refused before anything is written. This filter
  #    used to run at chain position 4 while ensure_team_member ran at position
  #    8, so a team-less user's 401 still left a GamePassing with team_id NULL
  #    behind it -- and game_passings/index.html.erb:65 and
  #    show_results.html.erb:61 both dereference game_passing.team.name, so
  #    that row permanently 500'd the author's stats page and the public
  #    results page, with no UI able to delete it.
  #
  # Before this, registration was enforced only in
  # shared/_current_games_status.html.erb, which hides the "Играть!" link for a
  # non-accepted entry but stops nothing: any user could create a team and GET
  # /play/:game_id for any started game, including one the author had
  # explicitly rejected.
  def find_or_create_game_passing
    @game_passing = GamePassing.of(@team, @game)
    return @game_passing if @game_passing

    unless may_start_passing?
      raise Authentication::Unauthorized, t("errors.not_registered_for_game")
    end

    @game_passing = GamePassing.create!(team: @team, game: @game,
                                        current_level: @game.levels.first)
  end

  # is_testing? is exempt and that exemption is load-bearing: a game in test
  # mode is played by the author's own team, which by construction has no
  # GameEntry (features/games/test-game-1.feature and test-game-2.feature both
  # fail without this). GameEntry.of dereferences team.id, so the nil check
  # must come first.
  def may_start_passing?
    return false if @team.nil?
    return true if @game.is_testing?

    GameEntry.of(@team, @game)&.status == "accepted"
  end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_registration_enforcement_spec.rb
```

Expected: 5 examples, 0 failures.

- [ ] **Step 6: Run both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec at your baseline plus 5 new examples, 0 failures. Cucumber **exactly** at baseline —
234 scenarios, 2358 steps, 2 undefined placeholders. Cucumber has been verified green against this
change; if it is not green for you, the difference is in your implementation, not in the suite.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/game_passings_controller.rb config/locales spec/requests/game_registration_enforcement_spec.rb
git commit -m "Require an accepted game entry before creating a game passing

Registration was enforced only in the views, which hide the play link but stop
no request. Any user could create a team and GET /play/:game_id for any started
game -- including a game whose entry the author had rejected -- consuming no
capacity slot, appearing in the author's stats and in the public results table.

Checked at creation rather than in a before_action so a team already mid-game
is never locked out by a status change, and so the nil-team case is refused
before the write: that path used to commit a team_id NULL row that 500'd the
author's stats page and the public results page permanently."
```

- [ ] **Step 8: Note the production cleanup for the deploy**

Orphan rows created before this fix are still in the production database and will keep 500ing those
pages. Do **not** write a migration that deletes data. Record this in the deploy notes for whoever
ships the release, to be run once against production after deploy:

```ruby
# kamal app exec -i 'bin/rails console'
GamePassing.where(:team_id => nil).count   # inspect first
GamePassing.where(:team_id => nil).delete_all
```

---

### Task 3: Scope the quiz option lookup to the current level

**Files:**
- Modify: `app/controllers/game_passings_controller.rb:143-146`
- Test: `spec/requests/quiz_option_scope_spec.rb` (create)

**Interfaces:**
- Consumes: nothing from Tasks 1-2 except the `create_game_entry` helper being available.
- Produces: nothing.

**Background:** `post_options` builds the echoed/logged answer string from **unvalidated** option
ids — `Option.where(:id => Array(option_ids)).pluck(:text)` — with no scoping to the question, level
or game. The scoping that exists is applied only in the *second* loop, which decides scoring. The
joined text lands in `@answer` and is rendered back to the player through
`game_passings.show_current_level.answer_incorrect` ("Код неверный, вы ввели '%{answer}'").
A player on any quiz level can therefore POST arbitrary option ids under a question id that matches
nothing — no penalty is charged, no state changes, and the response echoes the text of quiz options
from levels they have not reached and from other games entirely, enumerable by id.

Impact is bounded (the `is_correct` flag never leaks, and choices are shown to players on that level
anyway), which is why this is the smallest of the three fixes — but it is a free, unlimited read
oracle over the whole `options` table and it costs one line to close.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/quiz_option_scope_spec.rb`:

```ruby
require "rails_helper"

# post_options built the echoed answer string from unvalidated option ids, so a
# player on any quiz level could read back the text of options belonging to
# levels they had not reached and to other games -- free, unlimited, and with
# no penalty charged because the question id matched nothing.
describe "quiz option submission scoping", type: :request do
  let(:author)   { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.update_column(:starts_at, 1.hour.ago)
    g
  end
  let(:level)    { create_quiz_level(:game => game) }
  let(:question) { create_question(:level => level) }
  let(:passing)  { create_game_passing(:level => level) }
  let(:player) do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  let!(:mine) { create_option(:question => question, :text => "МОЙ ВАРИАНТ", :is_correct => true) }

  # A question on a different game entirely.
  let(:foreign_level)    { create_quiz_level }
  let(:foreign_question) { create_question(:level => foreign_level) }
  let!(:foreign_option) do
    create_option(:question => foreign_question, :text => "ЧУЖОЙ СЕКРЕТ", :is_correct => true)
  end

  before do
    passing
    put login_path, :params => { :email => player.email, :password => "1234" }
  end

  it "does not echo the text of options from another game" do
    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { foreign_question.id.to_s => [ foreign_option.id.to_s ] } }

    expect(response.body).not_to include("ЧУЖОЙ СЕКРЕТ")
  end

  it "does not log the text of options from another game" do
    expect {
      post post_answer_path(:game_id => game.id),
           :params => { :option_ids => { foreign_question.id.to_s => [ foreign_option.id.to_s ] } }
    }.to change { Log.count }.by(1)

    expect(Log.last.answer).not_to include("ЧУЖОЙ СЕКРЕТ")
  end

  it "still records a genuine selection on this level" do
    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { question.id.to_s => [ mine.id.to_s ] } }

    expect(Log.last.answer).to include("МОЙ ВАРИАНТ")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/quiz_option_scope_spec.rb
```

Expected: 3 examples, 2 failures — the foreign option's text appears both in the response body and
in the `Log` row. The third example passes already.

- [ ] **Step 3: Scope the lookup**

Replace `app/controllers/game_passings_controller.rb:143-146` with:

```ruby
    chosen_texts = []
    selections.each do |question_id, option_ids|
      # Scoped to this level's questions. Unscoped, this was a read oracle over
      # the whole options table: a crafted question_id matches nothing in the
      # scoring loop below, so no penalty was charged and nothing changed -- but
      # the plucked text still reached the player through @answer and the
      # answer_incorrect message, and was written to the author's log. Ids for
      # levels the team had not reached, and for other games, all resolved.
      chosen_texts.concat(
        Option.where(:id => Array(option_ids),
                     :question_id => @game_passing.current_level.questions.select(:id)).pluck(:text))
    end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/quiz_option_scope_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 5: Run the quiz coverage and both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/quiz_play_spec.rb spec/requests/quiz_authoring_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: all green. The documented ordering constraint in `post_options` (the comment at
`:154-158` — `save_log` must run before anything that can call `pass_level!`) is untouched by this
change, which is why the fix is a scoped query rather than a restructure of the two loops.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/game_passings_controller.rb spec/requests/quiz_option_scope_spec.rb
git commit -m "Scope quiz option lookup to the current level

The echoed answer string was built from unvalidated option ids, so a player on
any quiz level could POST arbitrary ids under a question id that matched
nothing: no penalty was charged and no state changed, but the response echoed
the option text back and the author's log recorded it. Ids from unreached
levels and from other games all resolved."
```

---

## Definition of done

- `bundle exec rspec` at baseline plus 8 new examples, 0 failures.
- `bundle exec cucumber` **exactly** at baseline: 234 scenarios, 2358 steps, 2 undefined.
- No file under `features/` has been modified — check with `git status features/`.
- The production cleanup command from Task 2 Step 8 is recorded in the release notes.
- Three commits, each independently revertable.
