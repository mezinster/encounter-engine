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
end
