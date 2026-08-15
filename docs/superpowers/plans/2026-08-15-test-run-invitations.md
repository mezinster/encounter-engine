# Test-run invitations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a game's author (or a superadmin) admit other teams — and individual players with no team — to a test run, by name or by a revocable link.

**Architecture:** A new `test_admissions` table records who may play one testing `GameRun`. A real team is admitted as itself; a solo player is admitted through a **disposable team that holds no members**, so `users.team_id` is never written and real membership is untouched. `GamePassingsController#find_team` becomes test-aware and resolves the disposable team; everything downstream of it is unchanged, because solo play *is* team play. `finish_test` sweeps admissions, disposable teams and the link token.

**Tech Stack:** Rails 8.1, Ruby 3.3.12, sqlite (dev/test), RSpec 3, Cucumber (Russian Gherkin — **read-only**).

**Spec:** `docs/superpowers/specs/2026-08-15-test-run-invitations-design.md` — read it before Task 1. The plan implements it; the spec argues for it.

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Every command below assumes you first ran:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit a `.feature` file.** All 59 are frozen. `features/games/test-game-1.feature` and `test-game-2.feature` cover the existing start/finish-test flow and must stay green *unchanged* — they are this feature's regression check.
- **Hash rockets (`:key => value`)**, including for symbol keys. Match the surrounding file.
- **Code, identifiers and comments in English; user-facing strings in Russian via `t()`.**
- **The test environment sets `raise_on_missing_translations`.** A `t()` call with no key raises rather than rendering a placeholder, so every task that adds a `t()` call adds its `ru` **and** `en` keys in the same commit. The other five locales (`uk`, `ka`, `tr`, `be`, `pl`) land in Task 9; `spec/i18n_spec.rb` requires them only to be a *subset* of `ru`, so they may lag until then without a red build.
- **Run `bin/rails db:test:prepare` after Task 1's migration**, before running any spec.
- **Object factories are plain helpers** in `spec/spec_helpers/fixtures_helper.rb` — not FactoryBot. `create_user` **takes no arguments**. Use `set_game_schedule!(game, :starts_at => ...)` to write run-scoped schedule columns.
- **Baseline at branch point** (`0c2fd77`): RSpec 1751 examples / 0 failures / 6 pending; Cucumber 238 scenarios (236 passed, 2 undefined) / 2386 steps. Any deviation beyond your own added examples is a regression.

---

## File Structure

| File | Responsibility |
|---|---|
| `db/migrate/20260815100000_create_test_admissions.rb` | The table and `game_runs.test_token` |
| `app/models/test_admission.rb` | Admission record; creation of disposable teams; revocation |
| `app/models/game_run.rb` (modify) | `has_many :test_admissions`; `#sweep_test_admissions!` |
| `app/models/game.rb` (modify) | Delegate `test_token` to the current run |
| `app/controllers/test_admissions_controller.rb` | Admit by name, revoke, reset token, link invite/join |
| `app/controllers/games_controller.rb` (modify) | Token lifecycle in `start_test`/`finish_test`; teardown sweep |
| `app/controllers/game_passings_controller.rb` (modify) | Test-aware `find_team`, `may_start_passing?`, `ensure_team_member` |
| `app/views/games/_test_admissions.html.erb` | The author's panel on `games#show` |
| `app/views/test_admissions/invite.html.erb` | Link confirmation page |
| `app/views/shared/_test_runs.html.erb` | Dashboard entry point for admitted testers |
| `config/routes.rb` (modify) | Six routes |
| `config/locales/*.yml` (modify) | Seven locales |

---

## Task 1: Schema and the `TestAdmission` model

**Files:**
- Create: `db/migrate/20260815100000_create_test_admissions.rb`
- Create: `app/models/test_admission.rb`
- Modify: `app/models/game_run.rb`
- Modify: `app/models/game.rb` (the `delegate` block at lines 43-51)
- Modify: `spec/spec_helpers/fixtures_helper.rb`
- Test: `spec/models/test_admission_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `TestAdmission` with `belongs_to :game_run, :team`, `belongs_to :user, optional: true`
  - `TestAdmission#solo?` → Boolean
  - `TestAdmission.of_run(run)`, `TestAdmission.solo` — scopes
  - `GameRun#test_admissions` (`dependent: :destroy`)
  - `Game#test_token`, `Game#test_token=` — delegated to `current_run`
  - `create_test_admission(:run => run, :team => team, :user => nil)` — fixture helper

- [ ] **Step 1: Write the migration**

```ruby
# Who, besides the author's own team, may play one TESTING run.
#
# Run-scoped rather than game-scoped, matching GameEntry: a test is one
# running of the content, and an admission must not survive into the next.
class CreateTestAdmissions < ActiveRecord::Migration[8.0]
  def change
    create_table :test_admissions do |t|
      t.integer  :game_run_id, :null => false
      # Always present, for BOTH kinds of admission: the play path resolves a
      # team and nothing else, so a solo admission names the disposable team
      # created for it rather than deferring that work into a GET request.
      t.integer  :team_id, :null => false
      # NULL means "a real team, playing as itself". Non-null means "one
      # player, playing solo in the disposable team named above". The
      # nullability IS the type discriminator.
      t.integer  :user_id
      t.datetime :created_at, :null => false
    end

    add_index :test_admissions, [ :game_run_id, :team_id ], :unique => true,
              :name => "index_test_admissions_on_run_and_team"
    # Partial, and the WHERE clause is load-bearing: without it two team
    # admissions (both user_id NULL) collide on the second insert.
    add_index :test_admissions, [ :game_run_id, :user_id ], :unique => true,
              :where => "user_id IS NOT NULL",
              :name => "index_test_admissions_on_run_and_user"

    # The link credential for a test run. Written by start_test, nil'd by
    # finish_test, regenerable by the author (which revokes the old link).
    add_column :game_runs, :test_token, :string
    add_index  :game_runs, :test_token, :unique => true
  end
end
```

- [ ] **Step 2: Run the migration and prepare the test database**

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

Expected: `db/schema.rb` gains `test_admissions` and `game_runs.test_token`.

- [ ] **Step 3: Write the failing model spec**

Create `spec/models/test_admission_spec.rb`:

```ruby
require "rails_helper"

describe TestAdmission do
  let(:game) { create_game }
  let(:run)  { game.current_run }

  before { run.update_column(:is_testing, true) }

  describe "#solo?" do
    it "is false for a team admission" do
      admission = TestAdmission.create!(:game_run => run, :team => create_team)
      admission.solo?.should be false
    end

    it "is true when a user is named" do
      admission = TestAdmission.create!(:game_run => run, :team => create_team,
                                        :user => create_user)
      admission.solo?.should be true
    end
  end

  it "refuses creation on a run that is not testing" do
    run.update_column(:is_testing, false)

    admission = TestAdmission.new(:game_run => run, :team => create_team)

    expect(admission).not_to be_valid
    expect(admission.errors[:game_run]).not_to be_empty
  end

  # The validation is :on => :create only, so teardown -- which clears
  # is_testing before it sweeps -- cannot be blocked by it.
  it "does not re-validate the testing flag on update" do
    admission = TestAdmission.create!(:game_run => run, :team => create_team)
    run.update_column(:is_testing, false)

    expect(admission.reload.save).to be true
  end

  describe "scopes" do
    it "of_run returns only that run's admissions" do
      mine  = TestAdmission.create!(:game_run => run, :team => create_team)
      other = create_game.current_run
      other.update_column(:is_testing, true)
      TestAdmission.create!(:game_run => other, :team => create_team)

      TestAdmission.of_run(run).to_a.should == [ mine ]
    end

    it "solo returns only admissions naming a user" do
      TestAdmission.create!(:game_run => run, :team => create_team)
      solo = TestAdmission.create!(:game_run => run, :team => create_team,
                                   :user => create_user)

      TestAdmission.of_run(run).solo.to_a.should == [ solo ]
    end
  end

  it "goes away with its run" do
    TestAdmission.create!(:game_run => run, :team => create_team)

    expect { run.destroy }.to change { TestAdmission.count }.by(-1)
  end
end
```

- [ ] **Step 4: Run it and verify it fails**

```bash
bundle exec rspec spec/models/test_admission_spec.rb
```

Expected: FAIL — `uninitialized constant TestAdmission`.

- [ ] **Step 5: Write the model**

Create `app/models/test_admission.rb`:

```ruby
# -*- encoding : utf-8 -*-
# Permission for someone other than the author to play one TESTING run.
#
# Two shapes, distinguished by user_id rather than by a type column:
#
#   user_id NULL     -- a real team, admitted as itself, playing with its own
#                       members.
#   user_id present  -- one player, admitted alone. team_id then names a
#                       DISPOSABLE team that holds no members and no captain.
#
# The disposable team is not a convenience. users.team_id is a single column
# and Team#adopt_captain writes it, so making a solo tester the captain of a
# fresh team would move them out of their real one and leave it captainless --
# the bricked state the 2026-08-08 team-membership programme exists to remove.
# A team with a passing and no members is strange-looking and correct.
class TestAdmission < ApplicationRecord
  belongs_to :game_run
  belongs_to :team
  belongs_to :user, :optional => true

  scope :of_run, ->(run) { where(:game_run_id => run.id) }
  scope :solo,   ->      { where.not(:user_id => nil) }

  # :on => :create deliberately. Teardown clears is_testing before it sweeps,
  # and a validation firing on every save would make the sweep unable to touch
  # the very rows it exists to remove.
  validate :run_is_testing, :on => :create

  def solo?
    self.user_id.present?
  end

  private

  def run_is_testing
    return if game_run&.is_testing?

    errors.add(:game_run, :not_testing)
  end
end
```

- [ ] **Step 6: Add the association and the delegation**

In `app/models/game_run.rb`, beside the other associations:

```ruby
  # dependent: :destroy so admissions cascade through
  # Game has_many :runs, dependent: :destroy when a game is deleted.
  has_many :test_admissions, :dependent => :destroy
```

In `app/models/game.rb`, add to the existing `delegate` block (lines 43-51), after `:test_date, :test_date=,`:

```ruby
           :test_token, :test_token=,
```

- [ ] **Step 7: Add the validation message to `ru` and `en`**

`config/locales/ru.yml`, under `activerecord: errors: models:` — add a `test_admission` entry alongside the existing models:

```yaml
        test_admission:
          attributes:
            game_run:
              not_testing: "не находится в режиме тестирования"
```

`config/locales/en.yml`, same path:

```yaml
        test_admission:
          attributes:
            game_run:
              not_testing: "is not in testing mode"
```

- [ ] **Step 8: Add the fixture helper**

In `spec/spec_helpers/fixtures_helper.rb`, after `create_game_entry`:

```ruby
  # The run must already be testing -- TestAdmission refuses otherwise. Callers
  # that build their own run should set is_testing before calling this.
  def create_test_admission(options={})
    run = options[:run] || create_game.current_run
    run.update_column(:is_testing, true) unless run.is_testing?

    TestAdmission.create!(:game_run => run,
                          :team     => options[:team] || create_team,
                          :user     => options[:user])
  end
```

- [ ] **Step 9: Run the spec and verify it passes**

```bash
bundle exec rspec spec/models/test_admission_spec.rb
```

Expected: PASS, 7 examples, 0 failures.

- [ ] **Step 10: Verify nothing else broke**

```bash
bin/rails zeitwerk:check
bundle exec rspec spec/models spec/i18n_spec.rb
```

Expected: 0 failures.

- [ ] **Step 11: Commit**

```bash
git add db/migrate db/schema.rb app/models/test_admission.rb app/models/game_run.rb app/models/game.rb config/locales/ru.yml config/locales/en.yml spec/models/test_admission_spec.rb spec/spec_helpers/fixtures_helper.rb
git commit -m "Add TestAdmission and the test-run link token"
```

---

## Task 2: Token lifecycle and the teardown sweep

**Files:**
- Modify: `app/controllers/games_controller.rb` (`start_test` at :109, `finish_test` at :206)
- Modify: `app/models/game_run.rb`
- Test: `spec/requests/test_run_teardown_spec.rb`

**Interfaces:**
- Consumes: `TestAdmission`, `GameRun#test_admissions`, `Game#test_token` (Task 1).
- Produces: `GameRun#sweep_test_admissions!` — deletes the run's admissions, destroys the disposable teams among them where `Team#deletable?`, and nils `test_token`. Returns nothing meaningful.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/test_run_teardown_spec.rb`:

```ruby
require "rails_helper"

# finish_test is the only thing standing between a test run and the real game.
# Anything it forgets outlives the test.
describe "finishing a test run", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
  end

  it "generates a token when the test starts" do
    game.current_run.test_token.should_not be_nil
  end

  it "clears the token when the test finishes" do
    post finish_test_game_path(game)

    game.reload.current_run.test_token.should be_nil
  end

  it "deletes the run's admissions" do
    create_test_admission(:run => game.current_run, :team => create_team)

    expect {
      post finish_test_game_path(game)
    }.to change { TestAdmission.count }.by(-1)
  end

  it "destroys a disposable team once its passing is gone" do
    tester = create_user
    team   = create_team
    create_test_admission(:run => game.current_run, :team => team, :user => tester)
    GamePassing.create!(:team => team, :game => game,
                        :game_run => game.current_run, :current_level => level)

    expect {
      post finish_test_game_path(game)
    }.to change { Team.exists?(team.id) }.from(true).to(false)
  end

  # The order in the sweep is load-bearing: Team#deletable? refuses any team
  # holding a passing, so consulting it before the passings are deleted spares
  # every disposable team. An unplayed test passes either way -- this is the
  # case that catches a wrong order.
  it "destroys a disposable team whose tester actually played" do
    tester = create_user
    team   = create_team
    create_test_admission(:run => game.current_run, :team => team, :user => tester)
    GamePassing.create!(:team => team, :game => game,
                        :game_run => game.current_run, :current_level => level)
    Log.create!(:game_id => game.id, :game_run_id => game.current_run.id,
                :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "x")

    post finish_test_game_path(game)

    Team.exists?(team.id).should be false
  end

  # The deletable? guard, not the happy path.
  it "never destroys a real team that was admitted" do
    captain = create_user
    real    = create_team(:captain => captain)
    create_test_admission(:run => game.current_run, :team => real)

    post finish_test_game_path(game)

    Team.exists?(real.id).should be true
  end
end
```

- [ ] **Step 2: Run it and verify it fails**

```bash
bundle exec rspec spec/requests/test_run_teardown_spec.rb
```

Expected: FAIL — the first example fails with `test_token` nil, because `start_test` does not generate one yet.

- [ ] **Step 3: Add the sweep to `GameRun`**

In `app/models/game_run.rb`:

```ruby
  # Everything a test run created, removed. Called by
  # GamesController#finish_test AFTER it has deleted the run's passings and
  # logs, and the order is not interchangeable -- see below.
  def sweep_test_admissions!
    admissions = TestAdmission.where(:game_run_id => id)

    # Collected BEFORE the admissions go, destroyed AFTER: destroying a team
    # first would leave a dangling team_id, and deleting the admissions first
    # would lose the list.
    solo_teams = admissions.where.not(:user_id => nil).map(&:team)

    # TestAdmission.where(...), NOT test_admissions.delete_all. delete_all on a
    # has_many proxy NULLIFIES the foreign key unless the association declares
    # dependent: :delete_all -- the same trap finish_test's own comment records
    # about GameRun#passings. game_run_id is NOT NULL so this would raise
    # rather than corrupt, but relying on a constraint to catch a known mistake
    # is one migration away from not catching it.
    admissions.delete_all

    # deletable? is evaluated here, after the caller has deleted the passings
    # and logs: these team objects were loaded fresh above with unloaded
    # associations, so game_passings.empty? and Log.where(team_id:) query their
    # post-deletion state. A team cached earlier in the request would report
    # stale associations and be spared. The guard also makes this safe against
    # an admission pointing at a REAL team -- deletable? refuses anything with
    # members, a captain, entries, passings or logs.
    solo_teams.each { |team| team.destroy if team.deletable? }

    update_column(:test_token, nil)
  end
```

- [ ] **Step 4: Generate the token in `start_test`**

In `app/controllers/games_controller.rb#start_test`, after the successful `save` and before `record_admin_action`:

```ruby
    # After the save, not before: the save can legitimately fail on the
    # translation-completeness gate, and a token minted for a test that never
    # started would be a live credential to an unpublished game.
    #
    # update_column for the same reason every other lifecycle writer on this
    # model uses it -- a game mid-test does not pass its own validations.
    @game.current_run.update_column(:test_token, SecureRandom.urlsafe_base64(24))
```

- [ ] **Step 5: Sweep in `finish_test`**

In `app/controllers/games_controller.rb#finish_test`, immediately after the existing `Log.of_run(...).delete_all` line (:230):

```ruby
    # After the two deletions above, deliberately: Team#deletable? refuses a
    # team that still holds a passing or a log line, so sweeping first would
    # spare every disposable team.
    @game.current_run.sweep_test_admissions!
```

- [ ] **Step 6: Run the spec and verify it passes**

```bash
bundle exec rspec spec/requests/test_run_teardown_spec.rb
```

Expected: PASS, 6 examples, 0 failures.

- [ ] **Step 7: Verify the frozen features still pass**

```bash
bundle exec cucumber features/games/test-game-1.feature features/games/test-game-2.feature
```

Expected: all scenarios pass, no file modified.

- [ ] **Step 8: Commit**

```bash
git add app/models/game_run.rb app/controllers/games_controller.rb spec/requests/test_run_teardown_spec.rb
git commit -m "Mint a test-run token on start_test, sweep everything on finish_test"
```

---

## Task 3: Play-time identity

**Files:**
- Modify: `app/controllers/game_passings_controller.rb` (`find_team` :313, `may_start_passing?` :391, `ensure_team_member` filter :40)
- Test: `spec/requests/test_run_play_spec.rb`

**Interfaces:**
- Consumes: `TestAdmission` (Task 1).
- Produces: `GamePassingsController#test_admission` (private) — the current user's solo admission for the current testing run, or `nil`.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/test_run_play_spec.rb`:

```ruby
require "rails_helper"

# may_start_passing?'s is_testing? exemption is scoped to the author's own team
# on purpose: widening it would let any authenticated user read every level and
# answer code of an unpublished game. An admission is the narrow widening.
describe "playing a test run you were admitted to", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }
  let(:run)    { game.current_run }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
    delete logout_path
  end

  it "refuses an authenticated stranger with no admission" do
    stranger = create_user
    stranger.update!(:team => create_team(:captain => stranger))
    sign_in(stranger)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:unauthorized)
  end

  it "lets an admitted real team play" do
    captain = create_user
    team    = create_team(:captain => captain)
    captain.update!(:team => team)
    create_test_admission(:run => game.reload.current_run, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
  end

  it "lets a teamless solo tester play through their disposable team" do
    tester = create_user
    team   = create_team
    create_test_admission(:run => game.reload.current_run, :team => team,
                          :user => tester)
    sign_in(tester)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
    GamePassing.where(:game_run_id => game.reload.current_run.id,
                      :team_id => team.id).count.should == 1
  end

  # The entire design in one assertion.
  it "never writes users.team_id for a solo tester who already has a team" do
    tester   = create_user
    real     = create_team(:captain => tester)
    tester.update!(:team => real)
    disposable = create_team
    create_test_admission(:run => game.reload.current_run, :team => disposable,
                          :user => tester)
    sign_in(tester)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
    tester.reload.team_id.should == real.id
    real.reload.captain_id.should == tester.id
    GamePassing.where(:team_id => disposable.id).count.should == 1
    GamePassing.where(:team_id => real.id).count.should == 0
  end

  # ensure_team_member reads users.team_id -- the one column this design never
  # writes -- so without an exemption it 401s the tester after everything else
  # has worked.
  it "does not require real team membership of a solo tester" do
    tester = create_user
    tester.team_id.should be_nil
    create_test_admission(:run => game.reload.current_run,
                          :team => create_team, :user => tester)
    sign_in(tester)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:ok)
  end

  it "still requires real team membership outside a test run" do
    stranger = create_user
    sign_in(stranger)

    get show_current_level_path(:game_id => game.id)

    response.should have_http_status(:unauthorized)
  end
end
```

- [ ] **Step 2: Run it and verify it fails**

```bash
bundle exec rspec spec/requests/test_run_play_spec.rb
```

Expected: FAIL on the admitted-team and solo examples with `401 unauthorized`.

- [ ] **Step 3: Make `find_team` test-aware**

Replace `find_team` in `app/controllers/game_passings_controller.rb` (:313-315):

```ruby
  # A solo test participant plays in a DISPOSABLE team they are not a member
  # of, so current_user.team -- which reads users.team_id -- is the wrong
  # answer for them and the right one for everybody else.
  #
  # Safe to consult @game.current_run here: find_game already runs first (:5
  # before :9), so this needs no change to the filter order, whose comment
  # documents a hint-clock bug caused by moving a filter in this chain.
  def find_team
    @team = test_admission&.team || current_user.team
  end

  # nil unless this game is in test mode AND the current user holds a solo
  # admission in its current run. Memoised because find_team, may_start_passing?
  # and ensure_team_member each ask.
  def test_admission
    return nil unless @game&.is_testing?

    @test_admission ||= TestAdmission.find_by(:game_run_id => @game.current_run.id,
                                              :user_id     => current_user.id)
  end
```

- [ ] **Step 4: Add the admission clause to `may_start_passing?`**

In `may_start_passing?` (:391), after the author exemption:

```ruby
    # Covers BOTH invitee kinds with one lookup, because an admission always
    # names a team: a real team's admission names itself, a solo admission
    # names the disposable team find_team has already resolved into @team.
    return true if @game.is_testing? &&
                   TestAdmission.exists?(:game_run_id => @game.current_run.id,
                                         :team_id     => @team.id)
```

- [ ] **Step 5: Exempt solo testers from `ensure_team_member`**

Add to `app/controllers/game_passings_controller.rb`, in the private section beside the other guards. This **overrides** `SecurityFilters#ensure_team_member` for this controller only; `super` reaches the module's version:

```ruby
  # SecurityFilters#ensure_team_member asks users.team_id, which is exactly
  # what a solo test participant does not have and must not be given. Scoped to
  # "holds an admission in this testing run" rather than to is_testing?
  # broadly -- the latter would drop the check for every stranger the moment a
  # game entered test mode.
  def ensure_team_member
    return if test_admission

    super
  end
```

- [ ] **Step 6: Run the spec and verify it passes**

```bash
bundle exec rspec spec/requests/test_run_play_spec.rb
```

Expected: PASS, 7 examples, 0 failures.

- [ ] **Step 7: Verify the play path did not regress**

```bash
bundle exec rspec spec/requests spec/controllers
bundle exec cucumber features/game-passing features/games
```

Expected: 0 failures; Cucumber all green.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/game_passings_controller.rb spec/requests/test_run_play_spec.rb
git commit -m "Resolve a solo tester's disposable team at play time"
```

---

## Task 4: Admitting a team by name

**Files:**
- Create: `app/controllers/test_admissions_controller.rb`
- Modify: `config/routes.rb`
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`
- Test: `spec/requests/test_admission_by_name_spec.rb`

**Interfaces:**
- Consumes: `TestAdmission` (Task 1).
- Produces:
  - Routes `test_admit_team_path(game_id)`, `test_admit_player_path(game_id)`, `revoke_test_admission_path(game_id, id)`, `reset_test_token_path(game_id)`, `test_invite_path(game_id, token)`, `join_test_path(game_id, token)`
  - `TestAdmissionsController#create_team`
  - Private `#ensure_game_is_testing`
  - i18n namespace `test_admissions.*`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, after the `post "/games/end_game/:id"` line (:215):

```ruby
  # Test-run invitations. All mutations are POST driven by button_to, for the
  # same reason recorded above for start_test/finish_test/end_game: this app
  # has no Turbo and no rails-ujs, so a GET link_to would leave them reachable,
  # unprotected by CSRF, from any crafted or prefetched link.
  post "/games/:game_id/test_admissions/team",         to: "test_admissions#create_team",   as: :test_admit_team
  post "/games/:game_id/test_admissions/player",       to: "test_admissions#create_player", as: :test_admit_player
  post "/games/:game_id/test_admissions/:id/revoke",   to: "test_admissions#revoke",        as: :revoke_test_admission
  post "/games/:game_id/test_token",                   to: "test_admissions#reset_token",   as: :reset_test_token

  # The link half. GET only CONFIRMS -- it renders a page with a POST button --
  # because the URL is designed to be pasted into a chat, where a link-preview
  # bot following it would otherwise silently admit whatever account it holds.
  get  "/games/:game_id/test/:token", to: "test_admissions#invite", as: :test_invite
  post "/games/:game_id/test/:token", to: "test_admissions#join",   as: :join_test
```

- [ ] **Step 2: Write the failing spec**

Create `spec/requests/test_admission_by_name_spec.rb`:

```ruby
require "rails_helper"

describe "admitting a team to a test run by name", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }
  let!(:level)     { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def start_test_as_author
    sign_in(author)
    post start_test_game_path(game)
    game.reload
    delete logout_path
  end

  before { start_test_as_author }

  it "admits a team the author names" do
    team = create_team(:captain => create_user)
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.to change { TestAdmission.count }.by(1)

    admission = TestAdmission.last
    admission.team_id.should == team.id
    admission.user_id.should be_nil
  end

  it "consumes no registration slot" do
    team = create_team(:captain => create_user)
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { game.reload.current_run.requested_teams_number }
  end

  it "lets a superadmin admit a team to somebody else's game" do
    team = create_team(:captain => create_user)
    sign_in(superadmin)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.to change { TestAdmission.count }.by(1)
  end

  it "records an audit entry for an operator" do
    team = create_team(:captain => create_user)
    sign_in(superadmin)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.to change { AdminAction.count }.by(1)
  end

  it "refuses a stranger" do
    team     = create_team(:captain => create_user)
    stranger = create_user
    sign_in(stranger)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "refuses when the game is not in test mode" do
    sign_in(author)
    post finish_test_game_path(game)
    team = create_team(:captain => create_user)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "reports an unknown team name without creating anything" do
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => "Нет такой" }
    }.not_to change { TestAdmission.count }

    follow_redirect!
    response.body.should include("Команда «Нет такой» не найдена")
  end

  it "is idempotent for an already-admitted team" do
    team = create_team(:captain => create_user)
    create_test_admission(:run => game.current_run, :team => team)
    sign_in(author)

    expect {
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }
    }.not_to change { TestAdmission.count }
  end
end
```

- [ ] **Step 3: Run it and verify it fails**

```bash
bundle exec rspec spec/requests/test_admission_by_name_spec.rb
```

Expected: FAIL — `uninitialized constant TestAdmissionsController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/test_admissions_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
# Who, besides the author's own team, may play a test run.
#
# Everything except #invite/#join is author-or-superadmin: ensure_author
# already returns early for superadmins, which is what satisfies the
# "or superadmin" half of this feature with no second permission concept.
class TestAdmissionsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :find_game
  before_action :ensure_author,             :except => [ :invite, :join ]
  # A locked author must not be able to bring fresh people into the game an
  # operator locked to investigate -- the same reasoning this filter's own
  # comment records for finish_test, which deletes the evidence.
  before_action :ensure_editing_not_locked, :except => [ :invite, :join ]
  before_action :ensure_game_is_testing

  def create_team
    team = Team.find_by(:name => params[:name].to_s.strip)

    if team.nil?
      return redirect_to game_path(@game),
                         :alert => t("test_admissions.team_not_found", :name => params[:name].to_s.strip)
    end

    if TestAdmission.exists?(:game_run_id => run.id, :team_id => team.id)
      return redirect_to game_path(@game),
                         :notice => t("test_admissions.already_admitted", :name => team.name)
    end

    TestAdmission.create!(:game_run => run, :team => team)
    record_admin_action("test_admit_team", @game, team.name) if acting_as_operator?(@game)

    redirect_to game_path(@game), :notice => t("test_admissions.team_admitted", :name => team.name)
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def run
    @run ||= @game.current_run
  end

  # Admissions exist only for the duration of a test. Outside one there is
  # nothing to grant and nothing to revoke.
  def ensure_game_is_testing
    raise Authentication::Unauthorized, t("errors.game_is_not_testing") unless @game.is_testing?
  end
end
```

- [ ] **Step 5: Add the `ru` keys**

`config/locales/ru.yml` — a new top-level `test_admissions:` block under the same parent as `games:`:

```yaml
    test_admissions:
      team_not_found: "Команда «%{name}» не найдена"
      already_admitted: "«%{name}» уже допущены к тестированию"
      team_admitted: "Команда «%{name}» допущена к тестированию"
```

And under the existing `errors:` block:

```yaml
      game_is_not_testing: "Игра не находится в режиме тестирования"
```

- [ ] **Step 6: Add the `en` keys**

`config/locales/en.yml`, same paths:

```yaml
    test_admissions:
      team_not_found: "Team «%{name}» was not found"
      already_admitted: "«%{name}» is already admitted to the test"
      team_admitted: "Team «%{name}» has been admitted to the test"
```

```yaml
      game_is_not_testing: "This game is not in testing mode"
```

- [ ] **Step 7: Run the spec and verify it passes**

```bash
bundle exec rspec spec/requests/test_admission_by_name_spec.rb
```

Expected: PASS, 8 examples, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/test_admissions_controller.rb config/routes.rb config/locales/ru.yml config/locales/en.yml spec/requests/test_admission_by_name_spec.rb
git commit -m "Admit a named team to a test run"
```

---

## Task 5: Admitting a solo player

**Files:**
- Modify: `app/models/test_admission.rb`
- Modify: `app/controllers/test_admissions_controller.rb`
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`
- Test: `spec/requests/test_admission_solo_spec.rb`, `spec/models/test_admission_spec.rb`

**Interfaces:**
- Consumes: Task 4's controller and routes.
- Produces:
  - `TestAdmission.admit_player!(run, user)` → `TestAdmission` — creates the disposable team and the admission in one transaction
  - `TestAdmission.disposable_team_name(user, run)` → String
  - `TestAdmissionsController#create_player`

- [ ] **Step 1: Write the failing model examples**

Append to `spec/models/test_admission_spec.rb`:

```ruby
describe TestAdmission, ".admit_player!" do
  let(:game) { create_game }
  let(:run)  { game.current_run }
  let(:user) { create_user }

  before { run.update_column(:is_testing, true) }

  it "creates a disposable team with no members and no captain" do
    admission = TestAdmission.admit_player!(run, user)

    admission.solo?.should be true
    admission.team.members.should be_empty
    admission.team.captain.should be_nil
  end

  it "does not touch the player's real membership" do
    real = create_team(:captain => user)
    user.update!(:team => real)

    TestAdmission.admit_player!(run, user)

    user.reload.team_id.should == real.id
    real.reload.captain_id.should == user.id
  end

  it "names the team after the player and the run" do
    admission = TestAdmission.admit_player!(run, user)

    admission.team.name.should == "#{user.nickname} (test ##{run.id})"
  end

  it "suffixes the name when a real team already holds it" do
    create_team(:name => "#{user.nickname} (test ##{run.id})")

    admission = TestAdmission.admit_player!(run, user)

    admission.team.name.should == "#{user.nickname} (test ##{run.id})-2"
  end

  it "leaves no orphan team when the admission cannot be created" do
    TestAdmission.admit_player!(run, user)

    expect {
      expect { TestAdmission.admit_player!(run, user) }.to raise_error(ActiveRecord::RecordNotUnique)
    }.not_to change { Team.count }
  end
end
```

- [ ] **Step 2: Write the failing request spec**

Create `spec/requests/test_admission_solo_spec.rb`:

```ruby
require "rails_helper"

describe "admitting a solo player to a test run", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
  end

  it "admits a player by nickname" do
    tester = create_user

    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }
    }.to change { TestAdmission.count }.by(1)

    TestAdmission.last.user_id.should == tester.id
  end

  it "creates exactly one disposable team" do
    tester = create_user

    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }
    }.to change { Team.count }.by(1)
  end

  it "refuses to admit the author, who is already exempt" do
    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => author.nickname }
    }.not_to change { TestAdmission.count }

    follow_redirect!
    response.body.should include("Автор уже может тестировать свою игру")
  end

  it "reports an unknown nickname" do
    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => "нетушки" }
    }.not_to change { TestAdmission.count }

    follow_redirect!
    response.body.should include("Игрок «нетушки» не найден")
  end

  it "is idempotent" do
    tester = create_user
    post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }

    expect {
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => tester.nickname }
    }.not_to change { TestAdmission.count }
  end
end
```

- [ ] **Step 3: Run both and verify they fail**

```bash
bundle exec rspec spec/models/test_admission_spec.rb spec/requests/test_admission_solo_spec.rb
```

Expected: FAIL — `undefined method 'admit_player!'`.

- [ ] **Step 4: Implement `admit_player!`**

Add to `app/models/test_admission.rb`, above `private`:

```ruby
  # The one place a disposable team is created. Transactional because a team
  # without its admission is an orphan nothing will ever sweep: teardown finds
  # disposable teams THROUGH their admissions.
  def self.admit_player!(run, user)
    transaction do
      team = Team.create!(:name => disposable_team_name(user, run))
      create!(:game_run => run, :team => team, :user => user)
    end
  end

  # teams.name is unique, so this must be collision-proof rather than
  # decorative. Untranslated and ASCII on purpose: it is stored data, read by
  # everyone in the run and shown in its log lines, and an i18n'd name would
  # freeze whichever locale the inviting author happened to be using.
  def self.disposable_team_name(user, run)
    base = "#{user.nickname} (test ##{run.id})"
    return base unless Team.exists?(:name => base)

    (2..10).each do |n|
      candidate = "#{base}-#{n}"
      return candidate unless Team.exists?(:name => candidate)
    end

    raise ArgumentError, "cannot find a free disposable team name for #{base}"
  end
```

- [ ] **Step 5: Add the controller action**

In `app/controllers/test_admissions_controller.rb`, after `create_team`:

```ruby
  def create_player
    nickname = params[:nickname].to_s.strip
    user     = User.find_by(:nickname => nickname)

    if user.nil?
      return redirect_to game_path(@game),
                         :alert => t("test_admissions.player_not_found", :name => nickname)
    end

    # The author plays a test run through may_start_passing?'s own exemption.
    # An admission would be a second, redundant grant -- and a disposable team
    # nobody uses for teardown to sweep.
    if @game.created_by?(user)
      return redirect_to game_path(@game), :notice => t("test_admissions.author_needs_no_admission")
    end

    if TestAdmission.exists?(:game_run_id => run.id, :user_id => user.id)
      return redirect_to game_path(@game),
                         :notice => t("test_admissions.already_admitted", :name => user.nickname)
    end

    TestAdmission.admit_player!(run, user)
    record_admin_action("test_admit_player", @game, user.nickname) if acting_as_operator?(@game)

    redirect_to game_path(@game),
                :notice => t("test_admissions.player_admitted", :name => user.nickname)
  end
```

- [ ] **Step 6: Add the `ru` keys**

Under `test_admissions:` in `config/locales/ru.yml`:

```yaml
      player_not_found: "Игрок «%{name}» не найден"
      player_admitted: "Игрок %{name} допущен к тестированию"
      author_needs_no_admission: "Автор уже может тестировать свою игру"
```

- [ ] **Step 7: Add the `en` keys**

Under `test_admissions:` in `config/locales/en.yml`:

```yaml
      player_not_found: "Player «%{name}» was not found"
      player_admitted: "Player %{name} has been admitted to the test"
      author_needs_no_admission: "The author can already test their own game"
```

- [ ] **Step 8: Run both specs and verify they pass**

```bash
bundle exec rspec spec/models/test_admission_spec.rb spec/requests/test_admission_solo_spec.rb
```

Expected: PASS, 12 + 5 examples, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add app/models/test_admission.rb app/controllers/test_admissions_controller.rb config/locales/ru.yml config/locales/en.yml spec/models/test_admission_spec.rb spec/requests/test_admission_solo_spec.rb
git commit -m "Admit a solo player through a disposable team"
```

---

## Task 6: Revoking an admission

**Files:**
- Modify: `app/models/test_admission.rb`
- Modify: `app/controllers/test_admissions_controller.rb`
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`
- Test: `spec/requests/test_admission_revoke_spec.rb`

**Interfaces:**
- Consumes: Tasks 4-5.
- Produces: `TestAdmission#revoke!` — deletes the team's passing in this run, destroys the disposable team if `deletable?`, destroys the admission. `TestAdmissionsController#revoke`.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/test_admission_revoke_spec.rb`:

```ruby
require "rails_helper"

# find_or_create_game_passing returns early the moment a passing exists, so
# may_start_passing? is consulted ONLY when there is none. A revoke that leaves
# the passing behind changes nothing at all -- the tester keeps playing while
# the panel shows them removed.
describe "revoking a test admission", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
  end

  it "deletes the admission" do
    admission = create_test_admission(:run => game.current_run, :team => create_team)

    expect {
      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)
    }.to change { TestAdmission.count }.by(-1)
  end

  it "deletes the tester's passing in this run" do
    tester    = create_user
    team      = create_team
    admission = create_test_admission(:run => game.current_run, :team => team, :user => tester)
    GamePassing.create!(:team => team, :game => game,
                        :game_run => game.current_run, :current_level => level)

    expect {
      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)
    }.to change { GamePassing.where(:team_id => team.id).count }.from(1).to(0)
  end

  it "actually stops the tester from playing" do
    tester    = create_user
    team      = create_team
    admission = create_test_admission(:run => game.current_run, :team => team, :user => tester)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)
    response.should have_http_status(:ok)

    delete logout_path
    sign_in(author)
    post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)
    response.should have_http_status(:unauthorized)
  end

  it "destroys the disposable team" do
    tester    = create_user
    team      = create_team
    admission = create_test_admission(:run => game.current_run, :team => team, :user => tester)

    post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

    Team.exists?(team.id).should be false
  end

  it "leaves a real team alone" do
    real      = create_team(:captain => create_user)
    admission = create_test_admission(:run => game.current_run, :team => real)

    post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

    Team.exists?(real.id).should be true
  end

  it "refuses a stranger" do
    admission = create_test_admission(:run => game.current_run, :team => create_team)
    delete logout_path
    sign_in(create_user)

    expect {
      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "refuses an admission belonging to another game" do
    other = create_game(:author => author, :is_draft => true)
    create_level(:game => other)
    other.current_run.update_column(:is_testing, true)
    foreign = create_test_admission(:run => other.current_run, :team => create_team)

    expect {
      post revoke_test_admission_path(:game_id => game.id, :id => foreign.id)
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:not_found)
  end
end
```

- [ ] **Step 2: Run it and verify it fails**

```bash
bundle exec rspec spec/requests/test_admission_revoke_spec.rb
```

Expected: FAIL — no route matches `revoke` action / `undefined method 'revoke'`.

- [ ] **Step 3: Implement `revoke!`**

Add to `app/models/test_admission.rb`, above `private`:

```ruby
  # Removing the row is NOT enough, and the difference is the whole point of
  # this method. GamePassingsController#find_or_create_game_passing returns the
  # existing passing before it ever calls may_start_passing?, so a tester who
  # has already opened the game keeps playing no matter what this table says.
  # The passing is the live grant; the admission only decides who may get one.
  #
  # Same ordering as GameRun#sweep_test_admissions!: passing first, then the
  # team, because Team#deletable? refuses a team that still holds one.
  def revoke!
    self.class.transaction do
      GamePassing.where(:game_run_id => game_run_id, :team_id => team_id).delete_all
      Log.where(:game_run_id => game_run_id, :team_id => team_id).delete_all

      doomed = solo? ? team : nil
      destroy
      doomed.destroy if doomed && doomed.reload.deletable?
    end
  end
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/test_admissions_controller.rb`, after `create_player`:

```ruby
  def revoke
    # Scoped to THIS run, not TestAdmission.find(params[:id]). An unscoped
    # lookup paired with an authorization check that never names the record is
    # the shape of the cross-tenant hole fixed in the level, question, answer,
    # option and hint controllers: the author of game A would be able to revoke
    # an admission belonging to game B.
    admission = TestAdmission.find_by(:id => params[:id], :game_run_id => run.id)

    raise ActiveRecord::RecordNotFound if admission.nil?

    label = admission.solo? ? admission.user&.nickname : admission.team.name
    admission.revoke!
    record_admin_action("test_revoke_admission", @game, label) if acting_as_operator?(@game)

    redirect_to game_path(@game), :notice => t("test_admissions.revoked", :name => label)
  end
```

- [ ] **Step 5: Add the `ru` and `en` keys**

`config/locales/ru.yml`, under `test_admissions:`:

```yaml
      revoked: "%{name} больше не участвует в тестировании"
```

`config/locales/en.yml`, under `test_admissions:`:

```yaml
      revoked: "%{name} is no longer part of the test"
```

- [ ] **Step 6: Run the spec and verify it passes**

```bash
bundle exec rspec spec/requests/test_admission_revoke_spec.rb
```

Expected: PASS, 7 examples, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add app/models/test_admission.rb app/controllers/test_admissions_controller.rb config/locales/ru.yml config/locales/en.yml spec/requests/test_admission_revoke_spec.rb
git commit -m "Revoke a test admission, deleting the passing that is the real grant"
```

---

## Task 7: The test link

**Files:**
- Modify: `app/controllers/test_admissions_controller.rb`
- Create: `app/views/test_admissions/invite.html.erb`
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`
- Test: `spec/requests/test_run_link_spec.rb`

**Interfaces:**
- Consumes: Tasks 1-6.
- Produces: `TestAdmissionsController#invite` (GET, renders confirmation), `#join` (POST, admits), `#reset_token`.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/test_run_link_spec.rb`:

```ruby
require "rails_helper"

describe "joining a test run by link", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def token
    game.reload.current_run.test_token
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
    delete logout_path
  end

  it "admits nobody on GET" do
    sign_in(create_user)

    expect {
      get test_invite_path(:game_id => game.id, :token => token)
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:ok)
  end

  it "admits on POST" do
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => token)
    }.to change { TestAdmission.count }.by(1)

    TestAdmission.last.solo?.should be true
  end

  it "refuses a wrong token" do
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => "wrong-token-entirely")
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "requires authentication" do
    post join_test_path(:game_id => game.id, :token => token)

    TestAdmission.count.should == 0
    response.should_not have_http_status(:ok)
  end

  it "is dead after the test finishes" do
    stale = token
    sign_in(author)
    post finish_test_game_path(game)
    delete logout_path
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => stale)
    }.not_to change { TestAdmission.count }

    response.should have_http_status(:unauthorized)
  end

  it "is dead after the author resets it" do
    stale = token
    sign_in(author)
    post reset_test_token_path(:game_id => game.id)
    game.reload.current_run.test_token.should_not == stale

    delete logout_path
    sign_in(create_user)

    expect {
      post join_test_path(:game_id => game.id, :token => stale)
    }.not_to change { TestAdmission.count }
  end

  it "does not admit the author twice" do
    sign_in(author)

    expect {
      post join_test_path(:game_id => game.id, :token => token)
    }.not_to change { TestAdmission.count }
  end

  it "is idempotent for someone already admitted" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)
    sign_in(tester)

    expect {
      post join_test_path(:game_id => game.id, :token => token)
    }.not_to change { TestAdmission.count }
  end
end
```

- [ ] **Step 2: Run it and verify it fails**

```bash
bundle exec rspec spec/requests/test_run_link_spec.rb
```

Expected: FAIL — `AbstractController::ActionNotFound` for `invite`.

- [ ] **Step 3: Add the actions**

In `app/controllers/test_admissions_controller.rb`, add to the filter list (so the token gate runs for the link pair only):

```ruby
  before_action :ensure_token_matches, :only => [ :invite, :join ]
```

and the actions, after `revoke`:

```ruby
  # GET. Renders a confirmation page and admits nobody. See the routes comment:
  # the link is meant to be pasted into a chat, and a link-preview bot that
  # follows it must not be able to admit the account it is authenticated as.
  def invite
    redirect_to show_current_level_path(:game_id => @game.id) if already_playing?
  end

  # POST. The actual grant.
  def join
    return redirect_to show_current_level_path(:game_id => @game.id) if already_playing?

    TestAdmission.admit_player!(run, current_user)

    redirect_to show_current_level_path(:game_id => @game.id),
                :notice => t("test_admissions.joined", :name => @game.name)
  end

  # Revokes the outstanding link by replacing it.
  def reset_token
    run.update_column(:test_token, SecureRandom.urlsafe_base64(24))
    record_admin_action("test_reset_token", @game) if acting_as_operator?(@game)

    redirect_to game_path(@game), :notice => t("test_admissions.token_reset")
  end
```

and the private helpers:

```ruby
  # The author needs no admission -- may_start_passing? exempts them -- and
  # anyone already admitted needs no second one.
  def already_playing?
    @game.created_by?(current_user) ||
      TestAdmission.exists?(:game_run_id => run.id, :user_id => current_user.id)
  end

  # secure_compare after the equality check on a token that is already looked
  # up by unique index: the index lookup is not what protects this, the 24
  # random bytes are, but constant-time comparison costs nothing and keeps the
  # habit intact for the next credential.
  def ensure_token_matches
    stored = run.test_token
    given  = params[:token].to_s

    valid = stored.present? &&
            ActiveSupport::SecurityUtils.secure_compare(stored, given)

    raise Authentication::Unauthorized, t("errors.bad_test_token") unless valid
  end
```

- [ ] **Step 4: Write the confirmation view**

Create `app/views/test_admissions/invite.html.erb`:

```erb
<%# The GET half of the test link. Renders a button and grants nothing -- see
    TestAdmissionsController#invite for why a GET must not admit. %>
<fieldset class="card">
  <legend><%= t("test_admissions.invite.legend") %></legend>

  <p><%= t("test_admissions.invite.explanation", :game => @game.name) %></p>

  <%= button_to t("test_admissions.invite.confirm"),
                join_test_path(:game_id => @game.id, :token => params[:token]),
                :class => "btn" %>
</fieldset>
```

- [ ] **Step 5: Add the `ru` keys**

Under `test_admissions:` in `config/locales/ru.yml`:

```yaml
      joined: "Вы допущены к тестированию игры «%{game}»"
      token_reset: "Прежняя ссылка больше не действует"
      invite:
        legend: "Приглашение на тестирование"
        explanation: "Вас приглашают протестировать игру «%{game}». Это черновик: результаты не сохранятся."
        confirm: "Присоединиться к тестированию"
```

Under `errors:`:

```yaml
      bad_test_token: "Ссылка на тестирование недействительна"
```

- [ ] **Step 6: Add the `en` keys**

Under `test_admissions:` in `config/locales/en.yml`:

```yaml
      joined: "You have been admitted to the test of «%{game}»"
      token_reset: "The previous link no longer works"
      invite:
        legend: "Test invitation"
        explanation: "You have been invited to test «%{game}». It is a draft: results will not be kept."
        confirm: "Join the test"
```

Under `errors:`:

```yaml
      bad_test_token: "This test link is not valid"
```

- [ ] **Step 7: Run the spec and verify it passes**

```bash
bundle exec rspec spec/requests/test_run_link_spec.rb
```

Expected: PASS, 8 examples, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/test_admissions_controller.rb app/views/test_admissions config/locales/ru.yml config/locales/en.yml spec/requests/test_run_link_spec.rb
git commit -m "Join a test run by revocable link, confirmed by POST"
```

---

## Task 8: The screens

**Files:**
- Create: `app/views/games/_test_admissions.html.erb`
- Create: `app/views/shared/_test_runs.html.erb`
- Modify: `app/views/games/show.html.erb` (the `is_testing?` block at :140-145)
- Modify: `app/views/dashboard/index.html.erb` (inside `div.dash-grid`, after the `shared/current_games` render at :10)
- Modify: `app/views/game_passings/show_current_level.html.erb:154` (the finish-testing button's guard)
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`
- Test: `spec/requests/test_admissions_screens_spec.rb`

**Interfaces:**
- Consumes: Tasks 1-7.
- Produces: no new Ruby interfaces. The panel posts to `test_admit_team_path` / `test_admit_player_path` / `revoke_test_admission_path` / `reset_test_token_path`.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/test_admissions_screens_spec.rb`:

```ruby
require "rails_helper"

describe "the test-run screens", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
  end

  it "shows the admissions panel to the author of a testing game" do
    get game_path(game)

    response.body.should include("Допуск к тестированию")
  end

  it "shows the link" do
    get game_path(game)

    response.body.should include(game.reload.current_run.test_token)
  end

  it "lists an admitted team with a revoke button" do
    team = create_team(:captain => create_user)
    create_test_admission(:run => game.current_run, :team => team)

    get game_path(game)

    response.body.should include(team.name)
    response.body.should include(revoke_test_admission_path(:game_id => game.id,
                                                            :id => TestAdmission.last.id))
  end

  it "hides the panel once the test is finished" do
    post finish_test_game_path(game)

    get game_path(game)

    response.body.should_not include("Допуск к тестированию")
  end

  it "offers a teamless tester a way into the game from the dashboard" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)

    delete logout_path
    sign_in(tester)
    get dashboard_path

    response.body.should include(game.name)
    response.body.should include(show_current_level_path(:game_id => game.id))
  end

  it "shows a teamless tester nothing when they hold no admission" do
    delete logout_path
    sign_in(create_user)

    get dashboard_path

    response.body.should_not include(game.name)
  end

  it "hides the exit control from a teamless solo tester" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)

    response.body.should_not include(exit_game_path(:game_id => game.id))
  end

  # finish_test deletes every passing and log line in the run and is behind
  # ensure_author. Offering its button to a tester is a 401 waiting to happen --
  # invisible until this feature put somebody other than the author in a test.
  it "hides the finish-testing button from a tester" do
    tester = create_user
    create_test_admission(:run => game.current_run, :team => create_team, :user => tester)

    delete logout_path
    sign_in(tester)
    get show_current_level_path(:game_id => game.id)

    response.body.should_not include(finish_test_game_path(game))
  end

  it "still shows the finish-testing button to the author" do
    get show_current_level_path(:game_id => game.id)

    response.body.should include(finish_test_game_path(game))
  end
end
```

- [ ] **Step 2: Run it and verify it fails**

```bash
bundle exec rspec spec/requests/test_admissions_screens_spec.rb
```

Expected: FAIL — the panel text is absent.

- [ ] **Step 3: Write the author's panel**

Create `app/views/games/_test_admissions.html.erb`:

```erb
<%# Author/superadmin only, and only while the game is in test mode. Rendered
    from games/show inside the existing is_testing? block. %>
<fieldset class="card">
  <legend><%= t("test_admissions.panel.legend") %></legend>

  <%= form_tag test_admit_team_path(:game_id => @game.id) do %>
    <%= label_tag :name, t("test_admissions.panel.team_label") %>
    <%= text_field_tag :name %>
    <%= submit_tag t("test_admissions.panel.admit_team"), :class => "btn" %>
  <% end %>

  <%= form_tag test_admit_player_path(:game_id => @game.id) do %>
    <%= label_tag :nickname, t("test_admissions.panel.player_label") %>
    <%= text_field_tag :nickname %>
    <%= submit_tag t("test_admissions.panel.admit_player"), :class => "btn" %>
  <% end %>

  <p>
    <%= t("test_admissions.panel.link_label") %>
    <%# Rendered as text, not as an anchor: the author's job is to copy it into
        a chat, and a clickable link on their own page only invites them to
        follow it themselves. %>
    <code><%= test_invite_url(:game_id => @game.id,
                              :token => @game.current_run.test_token) %></code>
    <%= button_to t("test_admissions.panel.reset_token"),
                  reset_test_token_path(:game_id => @game.id), :class => "btn" %>
  </p>

  <% admissions = TestAdmission.of_run(@game.current_run).includes(:team, :user) %>
  <% if admissions.any? %>
    <ul>
      <% admissions.each do |admission| %>
        <li>
          <%= admission.solo? ? admission.user&.nickname : admission.team.name %>
          <%= t("test_admissions.panel.solo_marker") if admission.solo? %>
          <%= button_to t("test_admissions.panel.revoke"),
                        revoke_test_admission_path(:game_id => @game.id,
                                                   :id => admission.id),
                        :class => "btn" %>
        </li>
      <% end %>
    </ul>
  <% else %>
    <p><%= t("test_admissions.panel.nobody_yet") %></p>
  <% end %>
</fieldset>
```

- [ ] **Step 4: Render it from `games/show`**

In `app/views/games/show.html.erb`, inside the existing `<% if @game.is_testing? %>` block (:140-145), after the `game-control` div:

```erb
  <%= render "test_admissions" if logged_in? && (@game.created_by?(current_user) || current_user.superadmin?) %>
```

- [ ] **Step 5: Write the tester's dashboard section**

Create `app/views/shared/_test_runs.html.erb`:

```erb
<%# Cannot live in shared/_current_games: that partial is wrapped in
    `if current_user.member_of_any_team?`, which is false for exactly the
    people this section exists for, and it skips testing games outright. %>
<% runs = GameRun.where(:is_testing => true)
                 .where(:id => TestAdmission.where(:user_id => current_user.id).select(:game_run_id))
                 .includes(:game) %>
<% if runs.any? %>
  <fieldset class="card">
    <legend><%= t("shared.test_runs.legend") %></legend>
    <% runs.each do |run| %>
      <p>
        <%= run.game.name %> |
        <%= link_to t("shared.test_runs.play"),
                    show_current_level_path(:game_id => run.game_id) %>
      </p>
    <% end %>
  </fieldset>
<% end %>
```

- [ ] **Step 6: Render it from the dashboard**

In `app/views/dashboard/index.html.erb`, inside `div.dash-grid`, immediately after the existing
`<%= render "shared/current_games" %>` at line 10:

```erb
  <%= render "shared/test_runs" %>
```

No `logged_in?` guard: the dashboard already requires authentication, and line 2 dereferences
`@current_user.nickname` unconditionally.

- [ ] **Step 7: Scope the in-game test controls to the author**

`app/views/game_passings/show_current_level.html.erb:149-156` currently reads:

```erb
<% if current_user.captain? || @game.is_testing? %>
  <div class="play-exit">
    <% if current_user.captain? %>
      <%= button_to t("game_passings.show_current_level.exit_game"), exit_game_path(:game_id => @game_passing.game_id), :class => "btn" %>
    <% end %>
    <% if @game.is_testing? %>
      <%= button_to t("game_passings.show_current_level.finish_testing"), finish_test_game_path(@game), :class => "btn" %>
    <% end %>
```

**The exit button needs no change** — its `current_user.captain?` guard already hides it from a
teamless solo tester, and a tester who *does* captain a real team can legitimately use it: `find_team`
has resolved `@team` to their disposable team, so it exits the test passing, which is what they meant.

**The finish-testing button does.** `@game.is_testing?` alone was a sound proxy for "you are the
author" only while the author's team was the only team that could ever be in a test run. This feature
breaks that assumption: every admitted tester would now see a button that `ensure_author` answers with
401 — and whose action deletes every passing and log line in the run. Change that one condition to:

```erb
    <% if @game.is_testing? && @game.created_by?(current_user) %>
```

Leave the outer `current_user.captain? || @game.is_testing?` alone — it also gates the surrounding
`div`, and a solo tester still needs it truthy for the answer form documented at `:83`.

- [ ] **Step 8: Add the `ru` keys**

Under `test_admissions:` in `config/locales/ru.yml`:

```yaml
      panel:
        legend: "Допуск к тестированию"
        team_label: "Название команды"
        admit_team: "Допустить команду"
        player_label: "Ник игрока"
        admit_player: "Допустить игрока"
        link_label: "Ссылка для тестировщиков:"
        reset_token: "Сменить ссылку"
        revoke: "Отозвать"
        solo_marker: "(в одиночку)"
        nobody_yet: "Пока никто не допущен"
```

Under `shared:` in `config/locales/ru.yml`:

```yaml
    test_runs:
      legend: "Тестирование"
      play: "Играть"
```

- [ ] **Step 9: Add the `en` keys**

Under `test_admissions:` in `config/locales/en.yml`:

```yaml
      panel:
        legend: "Test access"
        team_label: "Team name"
        admit_team: "Admit team"
        player_label: "Player nickname"
        admit_player: "Admit player"
        link_label: "Link for testers:"
        reset_token: "Replace the link"
        revoke: "Revoke"
        solo_marker: "(solo)"
        nobody_yet: "Nobody admitted yet"
```

Under `shared:` in `config/locales/en.yml`:

```yaml
    test_runs:
      legend: "Testing"
      play: "Play"
```

- [ ] **Step 10: Run the spec and verify it passes**

```bash
bundle exec rspec spec/requests/test_admissions_screens_spec.rb
```

Expected: PASS, 9 examples, 0 failures.

**Note:** `test_invite_url` needs a host. In request specs Rails supplies one; if the dashboard or panel raises `ArgumentError: Missing host`, that means it is being rendered outside a request — it is not, so do not add a `default_url_options` fallback to work around a symptom.

- [ ] **Step 11: Verify the frozen features still pass**

```bash
bundle exec cucumber features/games features/game-passing features/dashboard
```

Expected: all green, no `.feature` file modified.

- [ ] **Step 12: Commit**

```bash
git add app/views config/locales/ru.yml config/locales/en.yml spec/requests/test_admissions_screens_spec.rb
git commit -m "Screens: the author's admissions panel and the tester's way in"
```

---

## Task 9: The remaining five locales, and the gates

**Files:**
- Modify: `config/locales/uk.yml`, `ka.yml`, `tr.yml`, `be.yml`, `pl.yml`
- Test: `spec/i18n_spec.rb` (existing, no change)

**Interfaces:**
- Consumes: the complete `ru`/`en` key set from Tasks 1-8.
- Produces: seven locale files at equal key counts.

- [ ] **Step 1: List every key added so far**

```bash
git diff 0c2fd77 -- config/locales/ru.yml
```

Expected: the `test_admissions.*` block, `shared.test_runs.*`, `errors.game_is_not_testing`, `errors.bad_test_token`, and `activerecord.errors.models.test_admission.*`.

- [ ] **Step 2: Translate into `uk`, `be`, `pl`**

Add the same key paths to each file. These three are Slavic and take the `ru` structure directly. **Every `%{name}` / `%{game}` placeholder must survive verbatim** — `spec/i18n_spec.rb` compares interpolation variables.

- [ ] **Step 3: Translate into `ka` and `tr`, restructuring around the placeholders**

Both `%{name}` and `%{game}` carry user-authored values (a nickname, a team name, a game title). Turkish cannot attach a case suffix to them — which suffix is correct depends on the value's final vowel — so put the suffix on a common noun instead, the pattern the other 37 such keys use:

```yaml
      team_admitted: "«%{name}» adlı takım teste kabul edildi"
      player_admitted: "%{name} adlı oyuncu teste kabul edildi"
      joined: "«%{game}» adlı oyunun testine kabul edildiniz"
```

Georgian gets the same treatment: move the case ending onto a preceding common noun so it never lands on the interpolated value.

- [ ] **Step 4: Check the Turkish keys against both vowel classes**

```bash
bundle exec rails runner -e test 'I18n.locale = :tr; puts I18n.t("test_admissions.team_admitted", :name => "Kartal"); puts I18n.t("test_admissions.team_admitted", :name => "Gepardi")'
```

Expected: both read naturally. If only one does, the template is inflecting around the placeholder — rewrite it.

**Note:** `rails runner -e test` writes to `db/test.sqlite3`. Run `bin/rails db:test:prepare` afterwards before trusting a red suite.

- [ ] **Step 5: Confirm all seven files agree**

```bash
bundle exec rspec spec/i18n_spec.rb spec/i18n_play_screen_spec.rb spec/i18n_rails_defaults_spec.rb
```

Expected: 0 failures. `ru`↔`en` parity is exact; the other five must be subsets, and after this task they are complete.

- [ ] **Step 6: Run the full RSpec gate**

```bash
bundle exec rspec
```

Expected: 1751 + your new examples, 0 failures, 6 pending.

- [ ] **Step 7: Run the full Cucumber gate**

```bash
bundle exec cucumber
```

Expected: **238 scenarios (236 passed, 2 undefined), 2386 steps, 0 failed** — identical to the baseline. Any change here means the feature disturbed existing behaviour.

- [ ] **Step 8: Confirm no feature file was touched**

```bash
git diff --name-only 0c2fd77 -- features
```

Expected: **empty output**. Any line is a contract breach — revert it.

- [ ] **Step 9: Commit**

```bash
git add config/locales
git commit -m "Translate the test-invitation strings into the remaining five locales"
```

---

## Self-Review Notes

Checked against the spec, section by section:

| Spec § | Task |
|---|---|
| 2.1 `test_admissions`, both indexes | 1 |
| 2.2 `TestAdmission`, `solo?`, `run_is_testing` | 1 |
| 2.3 `game_runs.test_token`, generation, clearing, reset | 1 (column), 2 (generate/clear), 7 (reset) |
| 2.4 disposable teams, `deletable?` guard, naming with retry | 5 (naming), 2 + 6 (guard) |
| 3.1 admission by name, two buttons, all four refusals | 4 (team), 5 (player), 8 (buttons) |
| 3.1 team in a live real race admitted without objection | no code needed — no guard is added, and Task 4's spec admits a captained team |
| 3.2 link, GET confirms / POST admits, `secure_compare` | 7 |
| 4 `find_team`, `may_start_passing?` | 3 |
| 4.1 `ensure_team_member` | 3 |
| 4.1 `ensure_team_captain` / exit control | **no change needed** — `show_current_level.html.erb:151` already guards the exit button with `current_user.captain?`, so a teamless tester never sees it. Task 8 pins that with an example instead of adding code. |
| 4.2 `_test_runs.html.erb` | 8 |
| 5.1 `finish_test` sweep and its ordering | 2 |
| 5.2 revoke deletes the passing | 6 |
| 6 routes, filter chain, audit | 4 (routes, chain), 4-7 (audit calls) |
| 7 seven locales, Turkish/Georgian placeholder rule | 1, 4-8 (ru/en), 9 (the other five) |
| 8 all seven named specs | 2, 3, 4, 6, 7 |

Three things the spec leaves implicit that this plan makes explicit, and one deviation:

- **The finish-testing button is scoped to the author** (Task 8, Step 7). Not in the spec, and found
  while checking the spec's claim about the exit control. `show_current_level.html.erb:154` shows
  «Завершить тестирование» to anyone whose game `is_testing?` — sound only while the author was the
  only person who could be in a test run. This feature invalidates that assumption, and the action
  behind the button deletes every passing and log line in the run.

- **`Log` rows are deleted on revoke too** (Task 6). The spec's §5.2 names only the passing. `Team#deletable?` checks `Log.where(:team_id => id)`, so a disposable team whose tester answered anything would survive revocation without this. `finish_test` already deletes the run's logs wholesale, so §5.1 needed no equivalent.
- **`revoke` scopes its lookup to the run** (Task 6, Step 4). The spec does not say so; an unscoped `find` would let the author of one game revoke another game's admission.
- **No `Game#test_token` reader is used in views** — the panel reads `@game.current_run.test_token` directly. The delegation added in Task 1 exists for symmetry with the other run columns and for console use.
