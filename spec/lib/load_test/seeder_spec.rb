require "rails_helper"

describe LoadTest::Seeder do
  # let!, not let: create_level's default :game (build_level's `:game => create_game`)
  # is evaluated eagerly before `.merge(options)` overrides it, so every
  # create_level call below also creates one throwaway game+author. Left lazy,
  # that construction would happen on first reference to `source` -- which is
  # inside the very first example's `expect { seeder.seed! }` block -- and
  # inflate its User-count diff by those phantom accounts. Eager `let!` builds
  # `source` in a before hook, outside any example's measured block.
  let!(:source) do
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

  it "accepts a team count as a zero-padded string, as rake would pass it" do
    expect(described_class.new(:source_game => source, :teams => "03",
                               :cohort_id => "lt-test-a").seed![:teams].size).to eq(3)
  end

  # Seeding runs against PRODUCTION on run night, and production's SMTP is
  # Gmail, which suspends senders that trip its spam heuristics -- see the class
  # comment on RequestThrottling. Today no model or lib code mails at all (every
  # send site is in a controller), so seeding is silent. This pins that: an
  # after_create mailer added to User would otherwise start mailing hundreds of
  # addresses from production with nothing to catch it.
  it "sends no mail while seeding" do
    expect { seeder.seed! }.not_to change { ActionMailer::Base.deliveries.size }
  end

  describe "teardown" do
    # GameRun declares has_many :passings with NO dependent: option, on
    # purpose -- a passing is the record of a race somebody ran. So destroying
    # the game does NOT remove game_passings, and load-test rows would sit in
    # production for ever. This example is the guard for exactly that. Log,
    # Invitation, TeamJoinRequest and GameLocalePreference carry the identical
    # trap on Game/User/Team respectively, and are tracked for the same
    # reason.
    #
    # A `let`, not a top-level constant: a constant defined inside a
    # `describe` block lands on top-level `Object`, not on this example
    # group.
    let(:tracked) do
      [ User, Team, Game, Level, Question, Answer, Hint,
        GameRun, TestAdmission, GameEntry, GamePassing,
        PointTransaction, AccessPass, Log, Invitation,
        TeamJoinRequest, GameLocalePreference ]
    end

    it "restores every touched table to its pre-seed row count" do
      before_counts = tracked.to_h { |model| [ model.name, model.count ] }

      manifest = described_class.new(:source_game => source, :teams => 3,
                                     :cohort_id => "lt-test-a").seed!

      # seed! itself never writes any of these -- they are what gameplay
      # writes (an answer, an invite, a join request, a locale switch), which
      # the real k6 run does and the seeder does not. A tracked table left at
      # 0 before and 0 after proves nothing about whether its deletion line
      # in teardown! actually runs -- which is exactly how the Log leak this
      # example now guards against went unnoticed. One real row per table,
      # attached to the seeded cohort, so each deletion is genuinely
      # exercised.
      #
      # Built directly rather than through create_hint/create_access_pass:
      # both helpers default an argument via a hash literal evaluated BEFORE
      # `.merge(options)` runs (create_level, create_team respectively -- the
      # same eager-evaluation trap the comment on `source` above documents),
      # so passing :level/:team through them would still silently create an
      # extra, un-tracked-by-cohort Game/Level/Team alongside the one we ask
      # for and inflate the "after" counts for reasons that have nothing to
      # do with teardown.
      game    = Game.find(manifest[:game_id])
      team    = Team.find(manifest[:teams].first[:team_id])
      captain = team.captain
      author  = game.author
      level   = game.levels.first
      passing = GamePassing.find_by!(:game_id => game.id, :team_id => team.id)

      create_log(:game => game, :level => level, :team => team)
      Hint.create!(:level => level, :text => "Test hint", :delay => 60)
      create_game_entry(:game => game, :team_id => team.id)
      create_point_transaction(:passing => passing)
      game.update_column(:access_mode, "pass_required")
      AccessPass.create!(:game => game, :team => team, :source => "operator_invite")
      create_invitation(:for => author, :from => team)
      TeamJoinRequest.create!(:user => author, :team => team)
      GameLocalePreference.create!(:user => captain, :game => game, :locale => "en")

      described_class.teardown!("lt-test-a")

      expect(tracked.to_h { |model| [ model.name, model.count ] }).to eq(before_counts)
    end

    it "refuses to tear down a cohort that is not the one present" do
      described_class.new(:source_game => source, :teams => 2,
                          :cohort_id => "lt-test-a").seed!

      expect { described_class.teardown!("wrong-id") }.to raise_error(ArgumentError)
      # Nothing was deleted: the real cohort is still fully present.
      expect(described_class.status[:cohort_id]).to eq("lt-test-a")
      expect(described_class.status[:users]).to eq(2 * 3 + 1)
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
end
