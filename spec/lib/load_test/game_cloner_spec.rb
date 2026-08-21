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
