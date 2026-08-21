# Load Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repeatable way to measure how many concurrent teams the production VM carries before play becomes unacceptably slow.

**Architecture:** Two layers. A Rails-side *seed harness* (`lib/load_test/`) clones a real game into a throwaway cohort — teams, users, admissions, part-played passings — and emits a manifest JSON; it is driven either by rake or by a new superadmin console screen. A JS-side *k6 harness* (`load_test/`) reads that manifest and drives the real login and play routes from a throwaway Azure VM, in two phases: an SLO-bounded ramp to find the burst ceiling, then a sustained hold past CPU-credit exhaustion.

**Tech Stack:** Ruby 3.3.12 / Rails 8, RSpec, k6 (JavaScript), Azure CLI + cloud-init.

**Spec:** `docs/superpowers/specs/2026-08-21-load-testing-design.md` — read it first; this plan argues from it and does not restate its reasoning.

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Every command below assumes you have run `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` first.
- **Work in the worktree** `.claude/worktrees/load-testing`, branch `feature/load-testing`. Other sessions share this checkout; do not switch `master`.
- **Never edit any `features/**/*.feature` file.** No Cucumber work appears in this plan and none should be added. The inherited contract is 228 scenarios / 2325 steps and must stay green.
- **Hash rockets** (`:key => value`) throughout, matching surrounding files.
- **Code, identifiers and comments in English; user-facing strings in Russian via `t()`.**
- **A user-facing string needs all seven locales**: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`. `raise_on_missing_translations` is on in test, so a missing key is a red build.
- **Never assert `include(I18n.t("some.key"))` in a view spec** — that passes even when the key is missing, because both sides resolve identically. Pin the literal Russian string.
- **Isolate the test database** if another session may be running the suite: `DATABASE_URL="sqlite3:$SCRATCH/test.sqlite3" bundle exec rspec ...`.
- **Answer mix default is 85% wrong / 15% correct.** SLO thresholds are `p(95) < 2000ms` and `http_req_failed rate < 0.02`.
- **Never commit a manifest.** It contains live credentials for production accounts.
- **Nothing in the load path may touch a mailing endpoint.** Production SMTP is
  Gmail, which suspends senders that trip its spam heuristics (see the class
  comment on `RequestThrottling`). Signup, invitations and password reset are the
  six send sites, all in controllers; the k6 scenario uses `/login` and
  `/play/:game_id` only, and must never be extended to registration. Seeding
  itself writes at the model layer and is silent — pinned by a spec.

---

## Phase 1 — the seed harness (Rails)

### Task 1: `LoadTest::GameCloner`

**Files:**
- Create: `lib/load_test/game_cloner.rb`
- Test: `spec/lib/load_test/game_cloner_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `LoadTest::GameCloner.new(source_game).call(:name => String, :author => User) -> Game` (the persisted clone).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/lib/load_test/game_cloner_spec.rb
require "rails_helper"

describe LoadTest::GameCloner do
  let(:author) { create_user }

  it "copies every level in position order, with its codes" do
    source = create_game
    create_level(:game => source, :name => "L1", :correct_answer => "aaa")
    create_level(:game => source, :name => "L2", :correct_answer => "bbb")

    clone = described_class.new(source).call(:name => "scratch", :author => author)

    expect(clone.levels.map(&:name)).to eq(%w[L1 L2])
    expect(clone.levels.flat_map { |l| l.answers.map(&:value) }).to match_array(%w[aaa bbb])
  end

  it "copies hints with their delays" do
    source = create_game
    level = create_level(:game => source, :correct_answer => "aaa")
    Hint.create!(:level => level, :text => "подсказка", :delay => 300)

    clone = described_class.new(source).call(:name => "scratch", :author => author)

    expect(clone.levels.first.hints.map(&:delay)).to eq([ 300 ])
    expect(clone.levels.first.hints.map(&:text)).to eq([ "подсказка" ])
  end

  it "gives the clone the requested name and author, leaving the source alone" do
    source = create_game(:name => "Ночной Бишкек")
    create_level(:game => source, :correct_answer => "aaa")

    clone = described_class.new(source).call(:name => "scratch", :author => author)

    expect(clone.name).to eq("scratch")
    expect(clone.author).to eq(author)
    expect(source.reload.name).to eq("Ночной Бишкек")
  end

  # The half that matters. Asserting what was NOT copied is what catches a
  # future association on Game being swept into every clone by accident.
  it "copies no history, permission or files from the source" do
    source = create_game
    create_level(:game => source, :correct_answer => "aaa")
    team = create_team(:captain => create_user)
    GameEntry.create!(:game => source, :team => team, :status => "accepted")
    create_game_file(:game => source)

    clone = described_class.new(source).call(:name => "scratch", :author => author)

    expect(clone.game_entries).to be_empty
    expect(clone.game_passings).to be_empty
    expect(clone.game_files).to be_empty
    expect(clone.access_codes).to be_empty
    expect(clone.point_transactions).to be_empty
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/lib/load_test/game_cloner_spec.rb`
Expected: FAIL — `uninitialized constant LoadTest`.

- [ ] **Step 3: Implement the cloner**

```ruby
# lib/load_test/game_cloner.rb
#
# Deep-copies a real game's CONTENT into a throwaway one, so a load test can be
# seeded without authoring thirty levels by hand -- and so it loads the box with
# level text and code counts that actually exist.
#
# Deliberately not a Game instance method. This is a load-testing concern; as
# `Game#duplicate` it would become a general-purpose feature by accident, and
# would then need to answer questions about files, permissions and history that
# only have answers in this narrow context.
module LoadTest
  class GameCloner
    # Content, not history. Everything absent from this list is absent on
    # purpose: logs, entries, passings, access passes and codes, point
    # transactions and translation runs all belong to the game that was really
    # played. game_files is excluded too -- see the design, section 4.2.1: a
    # cloned level referencing a file renders that reference broken, which is
    # accepted rather than fixed, because copying blobs to a host with ~1.1 GB
    # spare buys marginal page weight on a CPU-bound test.
    GAME_ATTRIBUTES = %w[
      description primary_locale available_locales visibility access_mode
      points_enabled level_completion_points game_completion_points
      max_skips skip_points_fine skip_time_penalty
    ].freeze

    LEVEL_ATTRIBUTES = %w[
      text name position wrong_answer_penalty any_code_passes points_award
    ].freeze

    def initialize(source)
      @source = source
    end

    def call(name:, author:)
      clone = nil
      Game.transaction do
        clone = Game.new(@source.attributes.slice(*GAME_ATTRIBUTES))
        clone.name   = name
        clone.author = author
        # max_team_number is NOT a games column -- it lives on the run -- but
        # Game validates it unconditionally (app/models/game.rb:83, numericality
        # with no `on:` and no allow_nil), unlike GameRun's own copy which is
        # `on: :open`. A bare save! therefore fails on a nil the clone never set.
        clone.max_team_number = @source.max_team_number
        clone.save!
        @source.levels.order(:position).each { |level| copy_level(level, clone) }
      end
      clone.reload
    end

    private

    def copy_level(level, clone)
      copied = Level.new(level.attributes.slice(*LEVEL_ATTRIBUTES))
      copied.game = clone
      copied.save!

      # Questions first: answers carry question_id, so the mapping has to exist
      # before the answers are written or every code is orphaned.
      question_map = level.questions.each_with_object({}) do |question, map|
        map[question.id] = Question.create!(:level => copied,
                                            :questions => question.questions).id
      end

      level.answers.each do |answer|
        Answer.create!(:level_id    => copied.id,
                       :question_id => question_map[answer.question_id],
                       :value       => answer.value)
      end

      level.hints.each do |hint|
        Hint.create!(:level => copied, :text => hint.text, :delay => hint.delay)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bundle exec rspec spec/lib/load_test/game_cloner_spec.rb`
Expected: PASS, 4 examples, 0 failures.

If the "no history" example fails on `game_passings`, the likely cause is `Game`'s autobuilt run (`has_many :runs, autosave: true`) creating an ordinal-1 run on save. That is correct and expected; the assertion is about passings, not runs. Do not suppress the autobuild.

- [ ] **Step 5: Confirm autoloading is intact**

Run: `bin/rails zeitwerk:check`
Expected: `All is good!` — `lib/load_test/` must resolve as `LoadTest::`.

If it does not, `config.autoload_lib` is not picking up `lib/`. Check `config/application.rb` and add `config.autoload_lib(ignore: %w[tasks])` rather than requiring the file by hand.

- [ ] **Step 6: Commit**

```bash
git add lib/load_test/game_cloner.rb spec/lib/load_test/game_cloner_spec.rb
git commit -m "Clone a game's content for load-test seeding"
```

---

### Task 2: `LoadTest::Seeder#seed!` and the manifest

**Files:**
- Create: `lib/load_test/seeder.rb`
- Test: `spec/lib/load_test/seeder_spec.rb`

**Interfaces:**
- Consumes: `LoadTest::GameCloner#call` from Task 1.
- Produces: `LoadTest::Seeder.new(:source_game => Game, :teams => Integer, :cohort_id => String).seed! -> Hash` with symbol keys `:cohort_id, :game_id, :run_id, :base_url, :teams, :codes`. `:teams` is an array of `{ :email, :password, :team_id }`; `:codes` maps level id (String) to an array of code strings.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/lib/load_test/seeder_spec.rb
require "rails_helper"

describe LoadTest::Seeder do
  let(:source) do
    game = create_game
    create_level(:game => game, :name => "L1", :correct_answer => "aaa")
    create_level(:game => game, :name => "L2", :correct_answer => "bbb")
    game
  end

  def seeder(teams: 3)
    described_class.new(:source_game => source, :teams => teams,
                        :cohort_id => "lt-test-a", :base_url => "http://example.test")
  end

  it "creates one team of three users per requested team" do
    expect { seeder.seed! }.to change(Team, :count).by(3).and change(User, :count).by(9 + 1)
  end

  it "returns credentials that actually authenticate" do
    manifest = seeder(:teams => 1).seed!
    entry = manifest[:teams].first

    expect(User.find_by(:email => entry[:email]).authenticate(entry[:password])).to be_truthy
  end

  it "addresses every seeded account at the reserved .invalid TLD" do
    manifest = seeder.seed!

    expect(manifest[:teams].map { |t| t[:email] }).to all(end_with("@loadtest.invalid"))
  end

  it "admits each team to the run through TestAdmission, not GameEntry" do
    manifest = seeder.seed!
    run = GameRun.find(manifest[:run_id])

    expect(TestAdmission.where(:game_run_id => run.id).count).to eq(3)
    expect(GameEntry.where(:game_run_id => run.id).count).to eq(0)
  end

  it "opens the run in the past so play is not refused as not-yet-started" do
    manifest = seeder.seed!

    expect(GameRun.find(manifest[:run_id]).starts_at).to be < Time.now
  end

  it "never makes the author one of the players" do
    manifest = seeder.seed!
    author_email = Game.find(manifest[:game_id]).author.email

    expect(manifest[:teams].map { |t| t[:email] }).not_to include(author_email)
  end

  it "spreads passings across level depths rather than starting everyone at level 1" do
    manifest = seeder(:teams => 6).seed!
    depths = GamePassing.where(:game_id => manifest[:game_id]).pluck(:current_level_id).uniq

    expect(depths.size).to be > 1
  end

  it "publishes the real codes, keyed by the cloned level id" do
    manifest = seeder.seed!

    expect(manifest[:codes].values.flatten).to match_array(%w[aaa bbb])
  end

  it "refuses to seed while another cohort is present" do
    seeder.seed!

    expect { seeder.seed! }.to raise_error(LoadTest::Seeder::CohortPresent)
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/lib/load_test/seeder_spec.rb`
Expected: FAIL — `uninitialized constant LoadTest::Seeder`.

- [ ] **Step 3: Implement `seed!`**

```ruby
# lib/load_test/seeder.rb
#
# Builds and removes a load-test cohort. See
# docs/superpowers/specs/2026-08-21-load-testing-design.md.
#
# Every account this creates is a real row in a real database, with a real
# password, and on run night that database is production. Three properties are
# therefore structural rather than operational discipline: the password is
# generated per run and never constant, the addresses are unroutable, and
# seeding refuses while a previous cohort is still present so a forgotten
# teardown blocks the next run instead of silently doubling up.
module LoadTest
  class Seeder
    class CohortPresent < StandardError; end

    EMAIL_DOMAIN     = "loadtest.invalid".freeze
    MEMBERS_PER_TEAM = 3

    attr_reader :cohort_id

    def initialize(source_game:, teams:, cohort_id:, base_url: nil)
      @source_game = source_game
      # Integer(teams.to_s, 10), not Integer(teams, 10): the latter raises
      # "base specified for non string value" when handed an Integer, which
      # every spec does. Dropping the base instead is also wrong -- Integer("08")
      # raises -- and both real callers pass a string (rake args always are;
      # params[:teams] is one too), so a zero-padded count is reachable.
      @teams       = Integer(teams.to_s, 10)
      @cohort_id   = cohort_id
      @base_url    = base_url || ENV.fetch("LOAD_TEST_BASE_URL", "http://localhost:3000")
    end

    def seed!
      raise CohortPresent, "cohort #{existing_cohort} still present" if existing_cohort

      ActiveRecord::Base.transaction do
        author = create_account("author")
        game   = GameCloner.new(@source_game).call(:name => game_name, :author => author)
        run    = open_run(game)
        teams  = Array.new(@teams) { |i| build_team(game, run, i) }

        manifest(game, run, teams)
      end
    end

    private

    def game_name
      "НЕ ИГРА — нагрузочный тест #{@cohort_id}"
    end

    def prefix
      "#{@cohort_id}-"
    end

    def existing_cohort
      User.where("email LIKE ?", "%@#{EMAIL_DOMAIN}").limit(1).pluck(:email).first
    end

    # One password for the whole cohort: k6 holds it per VU and the cohort is
    # deleted within hours. Generated per run, never written to the repository.
    def password
      @password ||= SecureRandom.alphanumeric(32)
    end

    def create_account(label)
      nickname = "#{prefix}#{label}-#{SecureRandom.hex(4)}"
      User.create!(:nickname              => nickname,
                   :email                 => "#{nickname}@#{EMAIL_DOMAIN}",
                   :password              => password,
                   :password_confirmation => password)
    end

    # starts_at in the PAST: GamePassingsController refuses play with
    # game.not_started unless viewing_a_started_run?, so a run seeded with a
    # future date is seeded unplayable.
    def open_run(game)
      run = game.runs.order(:ordinal).last || game.runs.create!(:ordinal => 1)
      run.update!(:starts_at       => 1.hour.ago,
                  :max_team_number => @teams + 10,
                  :is_testing      => true,
                  :test_token      => SecureRandom.hex(16))
      run
    end

    def build_team(game, run, index)
      captain = create_account("t#{index}-captain")
      members = Array.new(MEMBERS_PER_TEAM - 1) { |m| create_account("t#{index}-m#{m}") }
      team    = Team.create!(:name => "#{prefix}team-#{index}", :captain => captain)
      ([ captain ] + members).each { |u| u.update!(:team_id => team.id) }

      # TestAdmission, not GameEntry: an is_testing run authorises through
      # `return if test_admission` in GamePassingsController, a separate branch
      # from the GameEntry one. user_id stays NULL so the admission is
      # team-wide, which the unique index permits.
      TestAdmission.create!(:game_run_id => run.id, :team_id => team.id)

      GamePassing.create!(:game_id                  => game.id,
                          :team_id                  => team.id,
                          :game_run_id              => run.id,
                          :current_level_id         => level_for(game, index).id,
                          :current_level_entered_at => Time.now)

      { :email => captain.email, :password => password, :team_id => team.id }
    end

    # Varied depth, not decoration: AnsweredQuestionsCoder re-serialises the
    # whole answered_questions blob on every accepted answer, so the write gets
    # more expensive the further a team has progressed. Starting everyone at
    # level 1 confines the test to the cheap end of that curve.
    def level_for(game, index)
      levels = game.levels.order(:position).to_a
      levels[index % levels.size]
    end

    def manifest(game, run, teams)
      { :cohort_id => @cohort_id,
        :game_id   => game.id,
        :run_id    => run.id,
        :base_url  => @base_url,
        :teams     => teams,
        :codes     => game.levels.order(:position).each_with_object({}) { |level, acc|
          acc[level.id.to_s] = level.answers.map(&:value)
        } }
    end
  end
end
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bundle exec rspec spec/lib/load_test/seeder_spec.rb`
Expected: PASS, 9 examples, 0 failures.

The `change(User, :count).by(9 + 1)` expectation counts three members per team plus the one author. If `create_account` is changed, update the arithmetic in the test rather than loosening the matcher.

- [ ] **Step 5: Commit**

```bash
git add lib/load_test/seeder.rb spec/lib/load_test/seeder_spec.rb
git commit -m "Seed a load-test cohort from a cloned game"
```

---

### Task 3: `LoadTest::Seeder.teardown!` and `.status`

**Files:**
- Modify: `lib/load_test/seeder.rb`
- Modify: `spec/lib/load_test/seeder_spec.rb`

**Interfaces:**
- Consumes: `LoadTest::Seeder#seed!` from Task 2.
- Produces: `LoadTest::Seeder.teardown!(cohort_id) -> Integer` (rows removed); `LoadTest::Seeder.status -> Hash` with keys `:cohort_id` (String or nil) and `:users` (Integer).

- [ ] **Step 1: Write the failing test**

Append to `spec/lib/load_test/seeder_spec.rb`:

```ruby
  describe "teardown" do
    # GameRun declares has_many :passings with NO dependent: option, on
    # purpose -- a passing is the record of a race somebody ran. So destroying
    # the game does NOT remove game_passings, and load-test rows would sit in
    # production for ever. This example is the guard for exactly that.
    TRACKED = [ User, Team, Game, Level, Question, Answer, Hint,
                GameRun, TestAdmission, GameEntry, GamePassing,
                PointTransaction, AccessPass ].freeze

    it "restores every touched table to its pre-seed row count" do
      before_counts = TRACKED.to_h { |model| [ model.name, model.count ] }

      described_class.new(:source_game => source, :teams => 3,
                          :cohort_id => "lt-test-a").seed!
      described_class.teardown!("lt-test-a")

      expect(TRACKED.to_h { |model| [ model.name, model.count ] }).to eq(before_counts)
    end

    it "leaves the source game and its levels untouched" do
      described_class.new(:source_game => source, :teams => 2,
                          :cohort_id => "lt-test-a").seed!
      described_class.teardown!("lt-test-a")

      expect(Game.find(source.id).levels.count).to eq(2)
    end

    it "reports no cohort once torn down" do
      described_class.new(:source_game => source, :teams => 2,
                          :cohort_id => "lt-test-a").seed!
      described_class.teardown!("lt-test-a")

      expect(described_class.status[:cohort_id]).to be_nil
    end

    # The guard for the parsing bug this method was originally written with.
    # A date-shaped id is what the rake task actually generates; the specs'
    # "lt-test-a" is the one shape under which a nickname regex looks correct.
    it "reports a date-shaped cohort id intact, as the rake task generates it" do
      described_class.new(:source_game => source, :teams => 1,
                          :cohort_id => "lt-2026-08-21-ab").seed!

      expect(described_class.status[:cohort_id]).to eq("lt-2026-08-21-ab")
    end

    it "reports the cohort while it is present" do
      described_class.new(:source_game => source, :teams => 2,
                          :cohort_id => "lt-test-a").seed!

      expect(described_class.status[:cohort_id]).to eq("lt-test-a")
      expect(described_class.status[:users]).to eq(2 * 3 + 1)
    end
  end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/lib/load_test/seeder_spec.rb -e teardown`
Expected: FAIL — `undefined method 'teardown!'`.

- [ ] **Step 3: Implement teardown and status**

First extract the game-name prefix into a constant so `status` and `game_name`
cannot drift apart. Beside the existing constants in `LoadTest::Seeder`:

```ruby
    # Shared by game_name (which writes it) and status (which reads the cohort
    # id back off it). A literal in two places is one edit away from silently
    # breaking status.
    GAME_NAME_PREFIX = "НЕ ИГРА — нагрузочный тест ".freeze
```

and change `game_name` to `"#{GAME_NAME_PREFIX}#{@cohort_id}"`. Its output must
be byte-identical to before — the existing Task 2 specs will tell you if it is not.

Then add to `LoadTest::Seeder`, inside the class:

```ruby
    class << self
      # Explicit deletion in dependency order, NOT a cascade. See the comment
      # on the teardown spec: GameRun has_many :passings carries no
      # dependent: option deliberately, so destroying the game leaves the
      # passings behind. Anything relying on cascades here would leave rows in
      # production and report success.
      def teardown!(cohort_id)
        present = status[:cohort_id]
        unless present == cohort_id
          raise ArgumentError,
                "cohort #{cohort_id.inspect} is not the cohort present (#{present.inspect})"
        end

        users = User.where("email LIKE ?", "%@#{EMAIL_DOMAIN}")
        games = Game.where(:author_id => users.select(:id))
        runs  = GameRun.where(:game_id => games.select(:id))

        # Ids are materialised NOW, before the detach below, and the teams are
        # deleted through `Team.where(:id => team_ids)` rather than through a
        # relation. A relation like `Team.where(:id => users.select(:team_id))`
        # is lazy: its subquery reads users.team_id, and `update_all` below sets
        # exactly that column to NULL, so by the time delete_all ran it would
        # match nothing. The teams would survive in production and only the
        # row-count example would notice.
        team_ids = users.pluck(:team_id).compact.uniq
        game_ids = games.pluck(:id)

        removed = 0
        ActiveRecord::Base.transaction do
          removed += PointTransaction.where(:team_id => team_ids).delete_all
          # Logs are the largest table a run writes -- one per answer POST --
          # and Game#logs carries no dependent: option, matching game_passings.
          # Deleted here, before the games are destroyed, by the same game_ids
          # already materialised above.
          removed += Log.where(:game_id => game_ids).delete_all
          removed += GamePassing.where(:game_run_id => runs.select(:id)).delete_all
          removed += GameEntry.where(:game_run_id => runs.select(:id)).delete_all
          removed += TestAdmission.where(:game_run_id => runs.select(:id)).delete_all
          removed += AccessPass.where(:game_id => game_ids).delete_all
          # Invitation/TeamJoinRequest are keyed by EITHER a user or a team on
          # either side (for_user_id/to_team_id, user_id/team_id), so both
          # sides of the cohort have to be checked -- a seeded user invited by
          # an outsider, or an outsider's request against a seeded team, is
          # exactly as real as the reverse. Users' ids, unlike their team_id,
          # are never mutated by this method, so reading them lazily off
          # `users` here is safe -- the row-count example would tell us if it
          # were not.
          removed += Invitation.where(:for_user_id => users.select(:id))
                                .or(Invitation.where(:to_team_id => team_ids)).delete_all
          removed += TeamJoinRequest.where(:user_id => users.select(:id))
                                    .or(TeamJoinRequest.where(:team_id => team_ids)).delete_all
          removed += GameLocalePreference.where(:user_id => users.select(:id)).delete_all
          # Detach before deleting the teams so users.team_id never dangles
          # even if a later delete raises and the transaction unwinds midway.
          users.update_all(:team_id => nil)
          removed += Team.where(:id => team_ids).delete_all
          # game.destroy!, not delete_all: levels/questions/answers/hints/runs/
          # game_entries/access_codes hang off the game by dependent: :destroy
          # and there is no FK to cascade here.
          Game.where(:id => game_ids).each { |game| game.destroy! ; removed += 1 }
          removed += users.delete_all
        end
        removed
      end

      # The cohort id comes from the seeded GAME's name, never from a nickname.
      # Recovering it from a nickname needs a pattern, and every pattern is
      # wrong for some id: /\A(lt-[^-]+-[^-]+)-/ reads the specs' "lt-test-a"
      # correctly and turns the rake task's own "lt-2026-08-21-ab" into
      # "lt-2026-08", because the date's hyphens eat the pattern. A spec using
      # only the short form stays green while the console misreports. The game
      # name is a fixed prefix followed by the id verbatim -- nothing to parse.
      def status
        users = User.where("email LIKE ?", "%@#{EMAIL_DOMAIN}")
        game  = Game.where("name LIKE ?", "#{GAME_NAME_PREFIX}%").order(:id).first
        { :cohort_id => game && game.name.delete_prefix(GAME_NAME_PREFIX),
          :users     => users.count }
      end
    end
```

- [ ] **Step 4: Run the whole seeder spec**

Run: `bundle exec rspec spec/lib/load_test/seeder_spec.rb`
Expected: PASS, 16 examples, 0 failures (11 from Task 2, 5 added here).

If the row-count example fails, read which model differs — that is the point of the example. Do not relax it to `be >=`; add the missing deletion.

- [ ] **Step 5: Commit**

```bash
git add lib/load_test/seeder.rb spec/lib/load_test/seeder_spec.rb
git commit -m "Tear a load-test cohort down and prove the tables are restored"
```

---

### Task 4: rake tasks and the production guard

**Files:**
- Create: `lib/tasks/load_test.rake`
- Test: `spec/lib/load_test/production_guard_spec.rb`

**Interfaces:**
- Consumes: `LoadTest::Seeder` from Tasks 2–3.
- Produces: `LoadTest.guard!(cohort_id)` — raises `LoadTest::Refused` under `RAILS_ENV=production` unless `ENV["LOAD_TEST_CONFIRM"] == cohort_id`. Rake tasks `load_test:seed[source_game_id,teams]`, `load_test:teardown[cohort_id]`, `load_test:status`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/lib/load_test/production_guard_spec.rb
require "rails_helper"

describe "LoadTest.guard!" do
  around do |example|
    original = ENV["LOAD_TEST_CONFIRM"]
    example.run
    ENV["LOAD_TEST_CONFIRM"] = original
  end

  it "allows anything outside production" do
    ENV.delete("LOAD_TEST_CONFIRM")

    expect { LoadTest.guard!("lt-a", :environment => "development") }.not_to raise_error
  end

  it "refuses in production without confirmation" do
    ENV.delete("LOAD_TEST_CONFIRM")

    expect { LoadTest.guard!("lt-a", :environment => "production") }
      .to raise_error(LoadTest::Refused)
  end

  it "refuses in production when the confirmation names a different cohort" do
    ENV["LOAD_TEST_CONFIRM"] = "lt-b"

    expect { LoadTest.guard!("lt-a", :environment => "production") }
      .to raise_error(LoadTest::Refused)
  end

  it "allows production when the confirmation matches exactly" do
    ENV["LOAD_TEST_CONFIRM"] = "lt-a"

    expect { LoadTest.guard!("lt-a", :environment => "production") }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/lib/load_test/production_guard_spec.rb`
Expected: FAIL — `undefined method 'guard!' for LoadTest`.

- [ ] **Step 3: Implement the guard**

```ruby
# lib/load_test.rb
#
# The guard is a separate, injectable check rather than a `Rails.env.production?`
# call inside the seeder, so it can be tested without pretending to be in
# production -- and so the console screen (task 5) enforces the same rule as the
# rake task rather than a lookalike.
module LoadTest
  class Refused < StandardError; end

  def self.guard!(cohort_id, environment: Rails.env)
    return unless environment.to_s == "production"

    # A blank id can never be confirmed, and this is checked BEFORE the
    # comparison rather than after. ENV["LOAD_TEST_CONFIRM"] is nil when unset
    # and the rake argument is nil when omitted, so `nil == nil` would read as
    # "confirmed" and authorise a nil-scoped sweep -- which matches the entire
    # cohort by e-mail domain -- against production with no confirmation at all.
    # An empty string pairs the same way.
    if cohort_id.to_s.empty?
      raise Refused, "a blank cohort id cannot be confirmed against production"
    end

    return if ENV["LOAD_TEST_CONFIRM"] == cohort_id

    raise Refused, "set LOAD_TEST_CONFIRM=#{cohort_id} to confirm this against production"
  end
end
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bundle exec rspec spec/lib/load_test/production_guard_spec.rb`
Expected: PASS, 4 examples, 0 failures.

- [ ] **Step 5: Add the rake tasks**

```ruby
# lib/tasks/load_test.rake
#
# A thin shell. The logic lives in lib/load_test/ so it is testable without
# invoking rake, and so the console screen drives exactly the same code.
namespace :load_test do
  desc "Seed a load-test cohort from a source game: rake load_test:seed[42,120]"
  task :seed, [ :source_game_id, :teams ] => :environment do |_t, args|
    cohort_id = ENV.fetch("LOAD_TEST_COHORT") { "lt-#{Date.today}-#{SecureRandom.hex(2)}" }
    LoadTest.guard!(cohort_id)

    manifest = LoadTest::Seeder.new(
      :source_game => Game.find(args.fetch(:source_game_id)),
      :teams       => args.fetch(:teams),
      :cohort_id   => cohort_id,
      :base_url    => ENV["LOAD_TEST_BASE_URL"]
    ).seed!

    path = ENV.fetch("LOAD_TEST_MANIFEST", "/tmp/#{cohort_id}.json")
    File.write(path, JSON.pretty_generate(manifest))
    File.chmod(0600, path)

    puts "cohort:   #{cohort_id}"
    puts "manifest: #{path}  (contains live credentials -- never commit it)"
    puts
    puts "TEARDOWN IS MANDATORY. When the run is over:"
    puts "  LOAD_TEST_CONFIRM=#{cohort_id} bin/rails 'load_test:teardown[#{cohort_id}]'"
  end

  # teardown! validates the id against the cohort actually present and refuses
  # on a mismatch, so a stale id cannot destroy a live cohort -- the guard only
  # compares two copies of what the operator typed, and cannot catch that on its
  # own.
  #
  # args[:cohort_id], not args.fetch: an omitted id must reach the guard as nil
  # and be refused there, rather than raising KeyError before any check runs.
  #
  # A cohort whose GAME was removed by hand cannot be named by status, so this
  # task cannot confirm it and will refuse. Sweeping those leftovers is a
  # deliberate out-of-band action -- `bin/rails runner 'puts
  # LoadTest::Seeder.teardown!(nil)'` -- which bypasses the guard because the
  # operator chose to step outside it. That belongs in the runbook, not behind a
  # rake flag: a guarded task must not offer an unguarded path.
  desc "Remove a load-test cohort: rake load_test:teardown[lt-2026-08-21-ab]"
  task :teardown, [ :cohort_id ] => :environment do |_t, args|
    cohort_id = args[:cohort_id]
    LoadTest.guard!(cohort_id)
    begin
      puts "removed #{LoadTest::Seeder.teardown!(cohort_id)} rows"
    rescue ArgumentError => e
      warn e.message
      warn "Check `load_test:status` first. If the cohort's game was removed by"
      warn "hand, status cannot name it and this task cannot confirm it; see"
      warn "docs/runbooks/load-test.md for the out-of-band sweep."
      raise
    end
    puts "status: #{LoadTest::Seeder.status.inspect}"
  end

  desc "Report whether a load-test cohort is present"
  task :status => :environment do
    puts LoadTest::Seeder.status.inspect
  end
end
```

- [ ] **Step 6: Exercise the tasks end to end against the dev database**

```bash
bin/rails 'load_test:seed[1,3]'     # substitute a real game id from your dev db
bin/rails load_test:status          # expect a cohort id and 10 users
bin/rails 'load_test:teardown[<cohort printed above>]'
bin/rails load_test:status          # expect cohort_id nil, users 0
```

Expected: the seed prints a manifest path; status reports the cohort; teardown reports a row count; status returns to nil/0.

- [ ] **Step 7: Commit**

```bash
git add lib/load_test.rb lib/tasks/load_test.rake spec/lib/load_test/production_guard_spec.rb
git commit -m "Drive the load-test seeder from rake, guarded in production"
```

---

### Task 5: the console controller, its guards and its audit trail

**Files:**
- Create: `app/controllers/admin/load_tests_controller.rb`
- Modify: `config/routes.rb` (inside the existing `namespace :admin do` block)
- Test: `spec/requests/admin/load_tests_spec.rb`
- Modify: `spec/requests/admin_audit_spec.rb`

**Interfaces:**
- Consumes: `LoadTest::Seeder`, `LoadTest.guard!`.
- Produces: routes `admin_load_test_path` (GET), `admin_load_test_seed_path` (POST), `admin_load_test_teardown_path` (POST), `admin_load_test_manifest_path` (GET). Audit action names `"load_test_seed"` and `"load_test_teardown"`.

- [ ] **Step 1: Write the failing request spec**

```ruby
# spec/requests/admin/load_tests_spec.rb
require "rails_helper"

describe "the load-test console", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:source) do
    game = create_game
    create_level(:game => game, :correct_answer => "aaa")
    game
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def seed_params(confirm:, cohort: "lt-test-a")
    { :source_game_id => source.id, :teams => 2,
      :cohort_id => cohort, :confirm_cohort_id => confirm }
  end

  it "refuses an ordinary signed-in user" do
    sign_in(create_user)
    get admin_load_test_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an operator who is not a superadmin" do
    operator = create_user
    operator.update!(:is_operator => true)
    sign_in(operator)

    get admin_load_test_path

    expect(response).to have_http_status(:unauthorized)
  end

  it "shows the screen to a superadmin" do
    sign_in(superadmin)
    get admin_load_test_path
    expect(response).to have_http_status(:ok)
  end

  # The typed confirmation must be ENFORCED, not merely rendered. A button that
  # creates hundreds of production accounts must not be one misclick.
  it "creates nothing when the typed cohort id does not match" do
    sign_in(superadmin)

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "wrong")
    }.not_to change(User, :count)
  end

  it "seeds when the typed cohort id matches" do
    sign_in(superadmin)

    expect {
      post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")
    }.to change(Team, :count).by(2)
  end

  # The manifest holds a live password per seeded captain and measures ~20 KB at
  # 120 teams, against a 4096-byte cookie. Putting it in the session would both
  # overflow and ship production credentials to the browser on every request.
  it "keeps the manifest itself out of the session, storing only a path" do
    sign_in(superadmin)

    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    expect(session[:load_test_manifest]).to be_nil
    expect(session[:load_test_manifest_path]).to be_present
    expect(session[:load_test_manifest_path]).not_to include("@loadtest.invalid")
  end

  it "offers the manifest as a download after seeding" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    get admin_load_test_manifest_path

    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(JSON.parse(response.body)["teams"].size).to eq(2)
  end

  it "tears the cohort down again" do
    sign_in(superadmin)
    post admin_load_test_seed_path, :params => seed_params(:confirm => "lt-test-a")

    expect {
      post admin_load_test_teardown_path,
           :params => { :cohort_id => "lt-test-a", :confirm_cohort_id => "lt-test-a" }
    }.to change(Team, :count).by(-2)
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/requests/admin/load_tests_spec.rb`
Expected: FAIL — `undefined local variable or method 'admin_load_test_path'`.

- [ ] **Step 3: Add the routes**

Inside the existing `namespace :admin do` block in `config/routes.rb`, after the settings routes:

```ruby
    # Load-test cohorts. A singular resource: there is one cohort at a time by
    # construction -- Seeder refuses to build a second while one is present.
    get  "/load_test",          to: "load_tests#show",     as: :load_test
    post "/load_test/seed",     to: "load_tests#seed",     as: :load_test_seed
    post "/load_test/teardown", to: "load_tests#teardown", as: :load_test_teardown
    get  "/load_test/manifest", to: "load_tests#manifest", as: :load_test_manifest
```

**The `as:` values matter and are easy to get backwards.** `namespace :admin`
prefixes the helper, exactly as the existing `admin_settings_path` shows — so
`as: :load_test_seed` yields `admin_load_test_seed_path`, and writing
`as: :seed_load_test` would yield `admin_seed_load_test_path` instead, which is
not what the specs, the controller or the view call. Confirm with:

```bash
bin/rails routes -g load_test
```

Expected helper names: `admin_load_test`, `admin_load_test_seed`,
`admin_load_test_teardown`, `admin_load_test_manifest`.

- [ ] **Step 4: Implement the controller**

```ruby
# -*- encoding : utf-8 -*-
#
# The console front door onto LoadTest::Seeder. It does not reimplement any of
# it: a screen holding its own copy of the seeding logic would drift from the
# rake task, and the two are used on the same night by the same person.
class Admin::LoadTestsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    @status = LoadTest::Seeder.status
    @games  = Game.order(:name)
  end

  def seed
    cohort_id = params[:cohort_id].to_s
    return refuse unless confirmed?(cohort_id)

    LoadTest.guard!(cohort_id)
    manifest = LoadTest::Seeder.new(
      :source_game => Game.find(params[:source_game_id]),
      :teams       => params[:teams],
      :cohort_id   => cohort_id,
      :base_url    => request.base_url
    ).seed!
    # Audited HERE, before the manifest write, and the order is load-bearing.
    # AdminAudit says to record after the change has landed -- the change is the
    # seed, not the file. ManifestFile uses File::EXCL, so a pre-existing path
    # raises Errno::EEXIST after seed! has committed; with the audit call below
    # the write, that leaves hundreds of production accounts with no record of
    # who created them and a 500 in the operator's browser.
    record_admin_action("load_test_seed", Game.find(manifest[:game_id]),
                        "cohort=#{cohort_id}, source=#{params[:source_game_id]}, " \
                        "teams=#{manifest[:teams].size}")

    begin
      store_manifest(manifest)
    rescue Errno::EEXIST
      # The cohort is live and recorded; only the credentials file is missing.
      # Name it so the operator can still tear down what they just created.
      return redirect_to(admin_load_test_path,
                         :alert => t("admin.load_test.manifest_exists", :cohort => cohort_id))
    end

    redirect_to admin_load_test_path, :notice => t("admin.load_test.seeded")
  rescue LoadTest::Seeder::CohortPresent, LoadTest::Refused => e
    redirect_to admin_load_test_path, :alert => e.message
  end

  def teardown
    cohort_id = params[:cohort_id].to_s
    return refuse unless confirmed?(cohort_id)

    LoadTest.guard!(cohort_id)
    removed = LoadTest::Seeder.teardown!(cohort_id)

    # Audited immediately, before the manifest cleanup, for the same reason as
    # in #seed. The change that touched the database is the teardown; the unlink
    # below can raise, and a raise there must not be able to erase the record of
    # who deleted a live cohort.
    record_admin_action("load_test_teardown", nil,
                        "cohort=#{cohort_id}, rows=#{removed}")

    # The credentials outlive the accounts otherwise. Best effort: a manifest we
    # cannot remove is worth a warning, not a 500 on a teardown that succeeded.
    # No File.exist? guard -- exist?-then-unlink is a TOCTOU race and /tmp is
    # exactly where a cleaner intervenes; the ENOENT rescue IS the check.
    path = session.delete(:load_test_manifest_path)
    begin
      File.unlink(path) if path.present?
    rescue Errno::ENOENT
      # Already gone.
    rescue SystemCallError => e
      Rails.logger.warn("[load_test] could not remove manifest #{path}: #{e.class}")
    end
    redirect_to admin_load_test_path, :notice => t("admin.load_test.torn_down")
  rescue LoadTest::Refused => e
    redirect_to admin_load_test_path, :alert => e.message
  end

  def manifest
    path = session[:load_test_manifest_path]
    if path.blank? || !File.exist?(path)
      return redirect_to(admin_load_test_path, :alert => t("admin.load_test.no_manifest"))
    end

    send_data File.read(path), :filename => "load-test-manifest.json",
                               :type => "application/json", :disposition => "attachment"
  end

  private

  def confirmed?(cohort_id)
    cohort_id.present? && params[:confirm_cohort_id].to_s == cohort_id
  end

  def refuse
    redirect_to admin_load_test_path, :alert => t("admin.load_test.not_confirmed")
  end

  # The PATH in the session, never the manifest itself -- and this is not a
  # preference, it is the only thing that works.
  #
  # This app uses Rails' default COOKIE session store (nothing in config/ sets
  # another), so anything put in the session is serialised into a 4096-byte
  # cookie. A 120-team manifest measures 20,365 bytes: the seed would commit to
  # the database and then raise ActionDispatch::Cookies::CookieOverflow on the
  # redirect, leaving a live cohort in production and the operator holding
  # nothing -- the same stranding failure as the EEXIST case in the rake task.
  #
  # It is also the wrong place on its own terms: the manifest holds a live
  # password for every seeded captain, and a cookie is sent to the browser and
  # back on every subsequent request.
  #
  # LoadTest::ManifestFile.write! already creates the file atomically at 0600
  # and refuses any path under Rails.root, so the console reuses it rather than
  # growing a second copy of that logic. The file lives in the container's
  # temporary directory and does not survive a deploy, which is the right
  # lifetime for credentials: if it is lost, tear the cohort down and re-seed.
  def store_manifest(manifest)
    session[:load_test_manifest_path] =
      LoadTest::ManifestFile.write!(manifest,
                                    :path => File.join(Dir.tmpdir, "#{manifest[:cohort_id]}.json"))
  end
end
```

- [ ] **Step 5: Add a minimal view so the task ends green**

Task 6 replaces this entirely. It exists now so this task's deliverable is
independently testable rather than handing the next task a red suite.

```erb
<%# app/views/admin/load_tests/show.html.erb %>
<h2>Нагрузочное тестирование</h2>
```

- [ ] **Step 6: Run the request spec**

Run: `bundle exec rspec spec/requests/admin/load_tests_spec.rb`
Expected: PASS, 7 examples, 0 failures.

- [ ] **Step 7: Add the two audit examples**

Append inside the top-level `describe` in `spec/requests/admin_audit_spec.rb`:

```ruby
  describe "load-test cohorts" do
    let(:source) do
      g = create_game
      create_level(:game => g, :correct_answer => "aaa")
      g
    end

    before { sign_in(superadmin) }

    it "records seeding a load-test cohort, naming the cohort and team count" do
      post admin_load_test_seed_path,
           :params => { :source_game_id => source.id, :teams => 2,
                        :cohort_id => "lt-test-a", :confirm_cohort_id => "lt-test-a" }

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("load_test_seed")
      expect(entry.details).to include("cohort=lt-test-a")
      expect(entry.details).to include("teams=2")
    end

    it "records tearing one down" do
      post admin_load_test_seed_path,
           :params => { :source_game_id => source.id, :teams => 2,
                        :cohort_id => "lt-test-a", :confirm_cohort_id => "lt-test-a" }
      post admin_load_test_teardown_path,
           :params => { :cohort_id => "lt-test-a", :confirm_cohort_id => "lt-test-a" }

      expect(AdminAction.newest_first.first.action).to eq("load_test_teardown")
    end

    it "records nothing when the confirmation does not match" do
      expect {
        post admin_load_test_seed_path,
             :params => { :source_game_id => source.id, :teams => 2,
                          :cohort_id => "lt-test-a", :confirm_cohort_id => "no" }
      }.not_to change(AdminAction, :count)
    end
  end
```

- [ ] **Step 8: Commit**

```bash
git add app/controllers/admin/load_tests_controller.rb config/routes.rb \
        app/views/admin/load_tests/show.html.erb \
        spec/requests/admin/load_tests_spec.rb spec/requests/admin_audit_spec.rb
git commit -m "Add a superadmin load-test console, audited and confirmation-gated"
```

---

### Task 6: the console view and seven locales

**Files:**
- Modify: `app/views/admin/load_tests/show.html.erb` (replacing Task 5's stub)
- Modify: `config/locales/ru.yml`, `en.yml`, `uk.yml`, `ka.yml`, `tr.yml`, `be.yml`, `pl.yml`
- Modify: `app/views/admin/dashboard/show.html.erb` (nav link)
- Test: `spec/requests/admin/load_tests_spec.rb` (extend)

**Interfaces:**
- Consumes: `@status`, `@games` from `Admin::LoadTestsController#show`.
- Produces: the `admin.load_test.*` key namespace.

- [ ] **Step 1: Write the failing view assertions**

Append to `spec/requests/admin/load_tests_spec.rb`:

```ruby
  # The literal Russian, NOT include(I18n.t(...)). Asserting against I18n.t
  # passes even when the key is missing, because both sides resolve to the same
  # "translation missing" string -- a vacuous assertion.
  it "names the screen and warns that seeding writes real accounts" do
    sign_in(superadmin)

    get admin_load_test_path

    expect(response.body).to include("Нагрузочное тестирование")
    expect(response.body).to include("создаёт настоящие учётные записи")
  end

  it "reports that no cohort is present on a clean database" do
    sign_in(superadmin)

    get admin_load_test_path

    expect(response.body).to include("Когорта не создана")
  end
```

- [ ] **Step 2: Run and confirm it fails**

Run: `bundle exec rspec spec/requests/admin/load_tests_spec.rb`
Expected: FAIL — the stub view carries the title but not the warning text, so
"warns that seeding writes real accounts" and "reports that no cohort is
present" both fail on missing body content.

- [ ] **Step 3: Write the view**

```erb
<%# app/views/admin/load_tests/show.html.erb %>
<h2><%= t("admin.load_test.title") %></h2>

<p class="warning"><%= t("admin.load_test.warning") %></p>

<% if @status[:cohort_id].present? %>
  <p>
    <%= t("admin.load_test.present", :cohort => @status[:cohort_id], :users => @status[:users]) %>
    <%= link_to t("admin.load_test.download_manifest"), admin_load_test_manifest_path %>
  </p>

  <%= form_with url: admin_load_test_teardown_path, method: :post do %>
    <%= hidden_field_tag :cohort_id, @status[:cohort_id] %>
    <div class="field">
      <%= label_tag :confirm_cohort_id,
            t("admin.load_test.confirm_label", :cohort => @status[:cohort_id]) %>
      <%= text_field_tag :confirm_cohort_id, nil, :autocomplete => "off" %>
    </div>
    <%= submit_tag t("admin.load_test.teardown"), :class => "btn btn--danger" %>
  <% end %>
<% else %>
  <p><%= t("admin.load_test.absent") %></p>

  <%= form_with url: admin_load_test_seed_path, method: :post do %>
    <div class="field">
      <%= label_tag :source_game_id, t("admin.load_test.source_game") %>
      <%= select_tag :source_game_id,
            options_from_collection_for_select(@games, :id, :name) %>
    </div>
    <div class="field">
      <%= label_tag :teams, t("admin.load_test.teams") %>
      <%= number_field_tag :teams, 120, :min => 1, :max => 1000 %>
    </div>
    <div class="field">
      <%= label_tag :cohort_id, t("admin.load_test.cohort_id") %>
      <%= text_field_tag :cohort_id, "lt-#{Date.today}-a", :autocomplete => "off" %>
    </div>
    <div class="field">
      <%= label_tag :confirm_cohort_id, t("admin.load_test.confirm_new_label") %>
      <%= text_field_tag :confirm_cohort_id, nil, :autocomplete => "off" %>
    </div>
    <%= submit_tag t("admin.load_test.seed"), :class => "btn btn--go" %>
  <% end %>
<% end %>
```

- [ ] **Step 4: Add the Russian keys**

Under `ru:` → `admin:` in `config/locales/ru.yml`:

```yaml
    load_test:
      title: "Нагрузочное тестирование"
      warning: "Внимание: посев создаёт настоящие учётные записи в этой базе. Обязательно удалите когорту после теста."
      absent: "Когорта не создана."
      present: "Когорта %{cohort}, учётных записей: %{users}."
      source_game: "Игра-источник"
      teams: "Количество команд"
      cohort_id: "Идентификатор когорты"
      confirm_new_label: "Повторите идентификатор когорты для подтверждения"
      confirm_label: "Введите «%{cohort}» для подтверждения"
      seed: "Создать когорту"
      teardown: "Удалить когорту"
      download_manifest: "Скачать манифест"
      seeded: "Когорта создана."
      torn_down: "Когорта удалена."
      not_confirmed: "Подтверждение не совпадает — ничего не сделано."
      no_manifest: "Манифест недоступен в этой сессии."
      manifest_exists: "Когорта %{cohort} создана, но манифест не записан: файл уже существует."
```

- [ ] **Step 5: Add the same block to the other six locale files**

`en.yml` must be an exact structural match — `spec/i18n_spec.rb` enforces `ru`↔`en` parity and will fail on any key present in one and absent from the other. English:

```yaml
    load_test:
      title: "Load testing"
      warning: "Warning: seeding creates real accounts in this database. Always remove the cohort when the test is over."
      absent: "No cohort present."
      present: "Cohort %{cohort}, accounts: %{users}."
      source_game: "Source game"
      teams: "Number of teams"
      cohort_id: "Cohort id"
      confirm_new_label: "Repeat the cohort id to confirm"
      confirm_label: "Type “%{cohort}” to confirm"
      seed: "Create cohort"
      teardown: "Remove cohort"
      download_manifest: "Download manifest"
      seeded: "Cohort created."
      torn_down: "Cohort removed."
      not_confirmed: "Confirmation did not match — nothing was done."
      no_manifest: "No manifest available in this session."
      manifest_exists: "Cohort %{cohort} was created, but the manifest was not written: that file already exists."
```

Then `uk`, `ka`, `tr`, `be`, `pl`. Two rules from `CLAUDE.md` apply:
- **Turkish:** `%{cohort}` is a user-typed value, so no case suffix may attach to it. Write `«%{cohort}» kimlikli kohort` ("the cohort with id X") rather than suffixing the placeholder. Check by rendering with a consonant-final and a vowel-final value.
- **Georgian:** move any case ending onto a preceding common noun rather than onto the interpolated value, for the same reason.

- [ ] **Step 6: Add the nav link**

In `app/views/admin/dashboard/show.html.erb`, beside the existing settings link:

```erb
<li><%= link_to t("admin.load_test.title"), admin_load_test_path %></li>
```

Match the surrounding markup — read the file first and follow whatever list structure is already there rather than assuming `<li>`.

- [ ] **Step 7: Run the i18n and console specs**

```bash
bundle exec rspec spec/i18n_spec.rb spec/requests/admin/load_tests_spec.rb spec/requests/admin_audit_spec.rb
```

Expected: all pass. A failure in `spec/i18n_spec.rb` naming a key means `ru` and `en` have diverged — fix the file, not the spec.

- [ ] **Step 8: Confirm the key count moved by exactly 16**

Measure the delta; do not compare against a remembered absolute. `CLAUDE.md`
records its own baseline as having been stale three times and says to recount
rather than reason about it.

```bash
COUNT='ruby -ryaml -e "def leaves(h,p=%q()) h.flat_map { |k,v| v.is_a?(Hash) ? leaves(v,%Q(#{p}#{k}.)) : [%Q(#{p}#{k})] } end
                       puts leaves(YAML.unsafe_load_file(%q(config/locales/ru.yml))[%q(ru)]).size"'
git stash && BEFORE=$(eval "$COUNT") && git stash pop && AFTER=$(eval "$COUNT")
echo "before=$BEFORE after=$AFTER delta=$((AFTER - BEFORE))"
```

Expected: `delta=17` — the seventeen keys in the block above. Any other number
means a key was missed or duplicated. Then update the absolute figure recorded
in `CLAUDE.md`'s i18n section to `$AFTER` in the same commit, and do the same
for the other six locale files (each must gain the same 16).

- [ ] **Step 9: Commit**

```bash
git add app/views/admin/load_tests/show.html.erb app/views/admin/dashboard/show.html.erb \
        config/locales/*.yml spec/requests/admin/load_tests_spec.rb CLAUDE.md
git commit -m "Render the load-test console in all seven locales"
```

---

### Task 7: Phase 1 gate

**Files:** none created; this task is verification.

- [ ] **Step 1: Run the whole RSpec suite**

Run: `bundle exec rspec`
Expected: 0 failures. Record the example count — `CLAUDE.md` says not to trust a quoted figure, so measure rather than compare to memory.

- [ ] **Step 2: Run the inherited Cucumber contract**

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: **228 scenarios (226 passed, 2 undefined), 2325 steps.** Nothing in Phase 1 touches a feature file, so any movement here is a real regression.

- [ ] **Step 3: Check autoloading**

Run: `bin/rails zeitwerk:check`
Expected: `All is good!`

- [ ] **Step 4: Boot the production environment**

```bash
RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u \
SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com \
DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'
```

Expected: `ok`. Neither suite evaluates `config/environments/production.rb`, so this is the only local check that the new `lib/` code does not break the image.

- [ ] **Step 5: Commit any fixes and push the branch**

```bash
git push -u origin feature/load-testing
```

---

## Phase 2 — the k6 harness

### Task 8: manifest and authentication modules, mutation-tested

**Files:**
- Create: `load_test/lib/manifest.js`, `load_test/lib/auth.js`, `load_test/main.js`
- Create: `load_test/README.md`

**Interfaces:**
- Consumes: the manifest JSON from Task 2.
- Produces: `manifest() -> Object`; `teamFor(vu) -> { email, password, team_id }`; `allCodes() -> String[]`; `csrfFrom(res) -> String`; `login(base, team) -> String` (the CSRF token for that VU's session — k6 keeps the cookie jar per VU automatically, so no jar is returned); `main.js` honouring `--env PHASE`, `--env MANIFEST`, `--env RATE`, `--env BASE_URL`.

- [ ] **Step 1: Install k6 locally**

```bash
curl -fsSL https://github.com/grafana/k6/releases/download/v0.52.0/k6-v0.52.0-linux-amd64.tar.gz \
  | tar xz --strip-components=1 -C /tmp k6-v0.52.0-linux-amd64/k6
sudo install /tmp/k6 /usr/local/bin/k6
k6 version
```

Expected: a version string. If the release tag 404s, list current tags with `gh release list -R grafana/k6` and use the newest v0.5x.

- [ ] **Step 2: Write the manifest module**

```js
// load_test/lib/manifest.js
import { SharedArray } from 'k6/data';

// SharedArray, not a bare JSON.parse: without it every VU holds its own parsed
// copy of the manifest, which at 200 VUs is 200 copies of every credential.
const data = new SharedArray('manifest', () =>
  [JSON.parse(open(__ENV.MANIFEST || './manifest.json'))]
);

export function manifest() {
  return data[0];
}

export function teamFor(vu) {
  const teams = manifest().teams;
  return teams[(vu - 1) % teams.length];
}

export function allCodes() {
  return Object.values(manifest().codes).flat();
}
```

- [ ] **Step 3: Write the auth module**

```js
// load_test/lib/auth.js
import http from 'k6/http';
import { check, fail } from 'k6';

// Rails masks the authenticity_token per render but accepts any valid
// unmasking for the SESSION. So this is scraped once per VU and cached:
// re-fetching before every POST would add a phantom GET to every write and
// distort the read/write ratio the whole test is trying to measure.
export function csrfFrom(res) {
  const m = res.body.match(/name="authenticity_token"\s+value="([^"]+)"/);
  if (!m) fail('no authenticity_token in response body');
  return m[1];
}

export function login(base, team) {
  const form = http.get(`${base}/login`);
  const token = csrfFrom(form);

  const res = http.post(`${base}/login`, {
    email: team.email,
    password: team.password,
    authenticity_token: token,
  });

  // Body content, NEVER status alone. k6 follows redirects, so a failed login
  // returns a cheerful 200 for the rest of the run and a status-only check
  // reports a flawless test against an app it never authenticated to.
  const ok = check(res, {
    'logged in': (r) => !r.body.includes('name="password"'),
  });
  if (!ok) fail(`login failed for ${team.email}`);

  return csrfFrom(res);
}
```

- [ ] **Step 4: Write a minimal `main.js` so the modules can be exercised**

Task 9 replaces this wholesale with the two-phase version. It exists now only so
the login path can be run and, more importantly, *mutation-tested* before any
play logic is layered on top.

```js
// load_test/main.js
import { manifest, teamFor } from './lib/manifest.js';
import { login } from './lib/auth.js';

export default function () {
  const base = __ENV.BASE_URL || manifest().base_url;
  login(base, teamFor(__VU));
}
```

- [ ] **Step 5: Seed a small local cohort and prove the login works**

```bash
bin/rails 'load_test:seed[1,5]'    # note the manifest path it prints
bin/rails server &                 # dev server on :3000
k6 run --env MANIFEST=/tmp/<cohort>.json --vus 2 --iterations 2 load_test/main.js
```

Expected: 0 failed checks, `logged in` at 100%.

- [ ] **Step 6: MUTATION TEST — break the password and confirm it goes red**

```bash
python3 -c "
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for t in d['teams']: t['password']='wrong'
json.dump(d,open('/tmp/broken.json','w'))
" /tmp/<cohort>.json
k6 run --env MANIFEST=/tmp/broken.json --vus 2 --iterations 2 load_test/main.js
```

Expected: **FAILS** with `login failed`. If this passes, the check is vacuous and the whole harness is worthless — fix it before going further. This is the exact failure mode `CLAUDE.md` records twice (the countdown examples reporting pending for a fortnight; the HEIC check reporting success on a machine that could not decode a byte).

- [ ] **Step 7: MUTATION TEST — break the CSRF token and confirm 422**

Temporarily change `csrfFrom` to `return 'invalid';` and re-run.
Expected: HTTP 422 from Rails' `protect_from_forgery`, surfaced as failed checks. Revert the change afterwards.

- [ ] **Step 8: Commit**

```bash
git add load_test/
git commit -m "Log a k6 virtual user in, and prove the check can fail"
```

---

### Task 9: the play loop and the two phases

**Files:**
- Create: `load_test/lib/play.js`
- Modify: `load_test/main.js`

**Interfaces:**
- Consumes: `login`, `manifest`, `teamFor`, `allCodes`.
- Produces: exported scenario functions `ramp` and `hold`.

- [ ] **Step 1: Write the play module**

```js
// load_test/lib/play.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { allCodes, manifest } from './manifest.js';

const WRONG_SHARE = Number(__ENV.WRONG_SHARE || 0.85);

function randomBetween(a, b) {
  return a + Math.random() * (b - a);
}

function pickCode() {
  if (Math.random() < WRONG_SHARE) return `wrong-${Math.floor(Math.random() * 1e9)}`;
  const codes = allCodes();
  return codes[Math.floor(Math.random() * codes.length)];
}

export function playOnce(base, token) {
  const gameId = manifest().game_id;

  const page = http.get(`${base}/play/${gameId}`);
  check(page, {
    // A distinguishing marker from the real play screen, not a status code.
    'on the level screen': (r) => r.body.includes('playbar-form'),
  });

  // The model, not padding. This app never polls -- the only setInterval is the
  // client-side countdown, which never contacts the server -- so an idle team
  // costs zero requests. Without think time the script would generate roughly
  // two orders of magnitude more traffic than the team count implies.
  sleep(randomBetween(20, 90));

  const res = http.post(`${base}/play/${gameId}`, {
    answer: pickCode(),
    authenticity_token: token,
  });
  check(res, {
    'answer accepted by the app': (r) => r.status !== 422 && r.status < 500,
  });

  sleep(randomBetween(5, 20));
}
```

- [ ] **Step 2: Write `main.js` with both phases**

```js
// load_test/main.js
import { manifest, teamFor } from './lib/manifest.js';
import { login } from './lib/auth.js';
import { playOnce } from './lib/play.js';

const PHASE = __ENV.PHASE || 'ramp';
const RATE  = Number(__ENV.RATE || 20);

const RAMP = {
  executor: 'ramping-arrival-rate',
  startRate: 0,
  timeUnit: '1s',
  preAllocatedVUs: 200,
  maxVUs: 400,
  stages: [
    { target: 10,  duration: '4m' },
    { target: 20,  duration: '4m' },
    { target: 40,  duration: '4m' },
    { target: 80,  duration: '4m' },
    { target: 120, duration: '4m' },
  ],
  exec: 'session',
};

const HOLD = {
  executor: 'constant-arrival-rate',
  rate: RATE,
  timeUnit: '1m',
  duration: '40m',
  preAllocatedVUs: 200,
  maxVUs: 400,
  exec: 'session',
};

export const options = {
  scenarios: PHASE === 'hold' ? { hold: HOLD } : { ramp: RAMP },
  // abortOnFail only in the ramp. The hold deliberately runs to completion:
  // its whole purpose is to observe what happens after the CPU credit bank
  // empties, which is a threshold breach by design, not a reason to stop.
  thresholds: {
    'http_req_duration': [
      { threshold: 'p(95)<2000', abortOnFail: PHASE === 'ramp', delayAbortEval: '30s' },
    ],
    'http_req_failed': [
      { threshold: 'rate<0.02', abortOnFail: PHASE === 'ramp', delayAbortEval: '30s' },
    ],
    'checks': ['rate>0.99'],
  },
};

// Module scope in k6 is PER VU, so this caches one login per virtual user for
// the whole run. Logging in every iteration would put a bcrypt verify on every
// play cycle, which measures a login storm rather than steady play and would
// report a sustained ceiling far below the truth -- defeating the entire point
// of the hold phase. (Modelling the real start-of-game login stampede wants its
// own scenario and its own design pass; it is out of scope here.)
let token = null;

export function session() {
  const base = __ENV.BASE_URL || manifest().base_url;
  if (token === null) {
    token = login(base, teamFor(__VU));
  }
  playOnce(base, token);
}
```

- [ ] **Step 3: Run a short ramp locally**

```bash
k6 run --env MANIFEST=/tmp/<cohort>.json --env PHASE=ramp \
       --env BASE_URL=http://localhost:3000 --duration 60s load_test/main.js
```

Expected: checks at 100%, no threshold abort against a local dev server.

- [ ] **Step 4: MUTATION TEST — confirm the abort actually fires**

```bash
k6 run --env MANIFEST=/tmp/<cohort>.json --env PHASE=ramp \
       --env BASE_URL=http://localhost:3000 --duration 60s \
       --env FORCE_SLOW=1 load_test/main.js
```

Since there is no `FORCE_SLOW` hook, instead temporarily lower the threshold to `p(95)<1` and re-run.
Expected: k6 **aborts** the run with a threshold-crossed message. If it does not, `abortOnFail` is not wired and the ramp has no brake — the single most important safety property in this design. Restore the threshold afterwards.

- [ ] **Step 5: Tear down the local cohort**

```bash
bin/rails 'load_test:teardown[<cohort>]'
bin/rails load_test:status     # expect cohort_id nil
```

- [ ] **Step 6: Commit**

```bash
git add load_test/
git commit -m "Ramp and hold phases for the k6 play loop"
```

---

### Task 10: the generator VM and the runbook

**Files:**
- Create: `load_test/provision.sh`, `load_test/cloud-init.yml`
- Create: `docs/runbooks/load-test.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `load_test/provision.sh create|destroy`.

- [ ] **Step 1: Write cloud-init**

```yaml
# load_test/cloud-init.yml
#
# cloud-init rather than an Ansible play, despite ansible/ being this repo's
# convention for host config: ansible/inventory.ini is pinned to the `mezin`
# ssh alias because WSL2 reaches that host through a ProxyCommand, so an
# ephemeral host would mean editing the inventory for every run.
#cloud-config
package_update: true
runcmd:
  - curl -fsSL https://github.com/grafana/k6/releases/download/v0.52.0/k6-v0.52.0-linux-amd64.tar.gz -o /tmp/k6.tgz
  - tar xzf /tmp/k6.tgz --strip-components=1 -C /tmp k6-v0.52.0-linux-amd64/k6
  - install /tmp/k6 /usr/local/bin/k6
  - /usr/local/bin/k6 version
```

- [ ] **Step 2: Write the provisioning script**

```bash
#!/usr/bin/env bash
# load_test/provision.sh — create or destroy the throwaway k6 generator.
#
# az CLI, not Terraform: this repository has no Terraform, no Bicep and no ARM,
# and its only infrastructure code is ansible/ configuring an existing host.
# Terraform earns its keep on long-lived resources with drift to manage; this
# VM lives about two hours.
#
# The resource group is the point. `az vm delete` leaves the NIC, NSG, public
# IP and OS disk behind, quietly billing; deleting the GROUP removes everything
# or fails loudly.
set -euo pipefail

RG="${LOAD_TEST_RG:-encounter-loadgen}"
LOCATION="${LOAD_TEST_LOCATION:-westeurope}"
VM="loadgen"

case "${1:-}" in
  create)
    az group create --name "$RG" --location "$LOCATION" --output none
    az vm create \
      --resource-group "$RG" --name "$VM" \
      --image Ubuntu2404 --size Standard_B1s \
      --admin-username azureuser --generate-ssh-keys \
      --custom-data "$(dirname "$0")/cloud-init.yml" \
      --output table
    echo
    echo "Copy the manifest up, then run k6 there:"
    echo "  scp <manifest.json> azureuser@<ip>:~/manifest.json"
    echo "  scp -r load_test azureuser@<ip>:~/"
    ;;
  destroy)
    az group delete --name "$RG" --yes --no-wait
    echo "deleting resource group $RG (async)"
    ;;
  *)
    echo "usage: $0 create|destroy" >&2; exit 64 ;;
esac
```

Then `chmod +x load_test/provision.sh`.

- [ ] **Step 3: Prove it round-trips**

```bash
./load_test/provision.sh create
# ssh in, confirm: k6 version
./load_test/provision.sh destroy
az group exists --name encounter-loadgen     # expect false, after a minute
```

Expected: `false`. If any resource survives, the group name was wrong — do not delete resources individually, fix the script.

- [ ] **Step 4: Write the runbook**

Create `docs/runbooks/load-test.md` containing, in this order and with commands spelled out:

1. **Pre-flight.** Query `game_runs` for any `starts_at` in the window and abort if a real game is scheduled. Confirm the wal-g backup is current (`docs/runbooks/restore.md`). Record a 10-minute idle baseline: p95 with no load, and the starting value of the `CPU Credits Remaining` metric in Azure Monitor.
2. **Seed** via `/admin/load_test`, download the manifest, and log in by hand as one seeded captain before launching anything.
3. **Provision** the generator, copy the manifest and `load_test/` up.
4. **Ramp:** `k6 run --env PHASE=ramp --env MANIFEST=~/manifest.json main.js`. Record the last plateau that did not abort — that is the burst ceiling.
5. **Hold:** `k6 run --env PHASE=hold --env RATE=<70% of ceiling> main.js` for 40 minutes. Watch credits drain; the latency at the moment they reach zero is the number that predicts hour two of a real game.
6. **Abort criteria a human owns**, which k6 cannot see: credits draining faster than the plateau schedule predicts; distress in danted, the squid proxies on 3128-3130/8080-8081, or the two APRS forwarders; any sign of a real user on the box.
7. **Teardown, mandatory:** tear the cohort down from the console, confirm `load_test:status` reports nil, destroy the resource group, and `kamal app boot` if memory ballooned — on ~1.1 GB spare a grown Puma worker does not necessarily shrink back.

- [ ] **Step 5: Commit and open the PR**

```bash
git add load_test/provision.sh load_test/cloud-init.yml docs/runbooks/load-test.md
git commit -m "Provision the k6 generator and write the run-night runbook"
git push
gh pr create --fill
```

---

## Post-merge: the questions this plan cannot answer

These are from the spec's section 8 and are resolved by *running* the thing, not by implementing it. Record the answers in the spec afterwards.

1. Whether the `is_testing` token gate actually refuses an uninvited authenticated user. If it does not, switch the seeded run to `access_mode: "pass_required"`.
2. Whether a cloned level whose text references a `game_file` renders an error or merely a broken link. An error would force copying the files or rewriting the text on clone.
3. Whether the 10→120 plateau ladder brackets the real ceiling, or needs re-scaling after the first ramp.
