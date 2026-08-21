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
  #
  # All eight of Game's history/permission/file associations are checked here
  # -- logs, game_entries, game_passings, access_passes, access_codes,
  # point_transactions, translation_runs, game_files -- not a subset, since a
  # partial list would give false assurance about exactly the associations it
  # omits. access_passes and translation_runs are asserted empty without a
  # source-side row: creating one of either requires setup this example
  # otherwise has no reason to carry (a gated game for the former, no fixture
  # helper at all for the latter), so those two assertions pin "the cloner
  # never populates this association" rather than "the cloner drops this
  # specific row" -- still enough to catch a future has_many swept in by
  # autosave, which is the failure mode this test exists for.
  it "copies no history, permission or files from the source" do
    source = create_game
    level = create_level(:game => source, :correct_answer => "aaa")
    team = create_team(:captain => create_user)
    GameEntry.create!(:game => source, :team => team, :status => "accepted")
    create_game_file(:game => source)
    create_log(:game => source, :level => level, :team => team)

    clone = described_class.new(source).call(:name => "scratch", :author => author)

    expect(clone.game_entries).to be_empty
    expect(clone.game_passings).to be_empty
    expect(clone.game_files).to be_empty
    expect(clone.access_codes).to be_empty
    expect(clone.point_transactions).to be_empty
    expect(clone.logs).to be_empty
    expect(clone.access_passes).to be_empty
    expect(clone.translation_runs).to be_empty
  end
end
