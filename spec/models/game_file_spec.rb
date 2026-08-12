require "rails_helper"

describe GameFile do
  before(:each) do
    @game = create_game
  end

  it "requires a game" do
    file = GameFile.new(:filename => "дом.jpg", :content_type => "image/jpeg")

    expect(file).not_to be_valid
    expect(file.errors[:game]).not_to be_empty
  end

  it "requires a filename" do
    file = GameFile.new(:game => @game, :content_type => "image/jpeg")

    expect(file).not_to be_valid
  end

  it "allows the same filename in two different games" do
    other = create_game
    create_game_file(:game => @game, :filename => "дом.jpg")

    expect(build_game_file(:game => other, :filename => "дом.jpg")).to be_valid
  end

  it "refuses a duplicate filename within one game" do
    create_game_file(:game => @game, :filename => "дом.jpg")

    duplicate = build_game_file(:game => @game, :filename => "дом.jpg")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:filename]).not_to be_empty
  end

  describe "storage accounting" do
    it "counts the canonical bytes AND the derived variants" do
      # A 5 MB original yielding a 240 KB web and an 18 KB thumb occupies all
      # three on disk, so all three count against the quota.
      file = create_game_file(:game => @game, :byte_size => 5_000_000,
                                              :derived_byte_size => 258_000)

      expect(file.total_byte_size).to eq(5_258_000)
    end

    it "sums a game's whole library" do
      create_game_file(:game => @game, :byte_size => 1_000, :derived_byte_size => 100)
      create_game_file(:game => @game, :byte_size => 2_000, :derived_byte_size => 200)

      expect(GameFile.storage_used_by(@game)).to eq(3_300)
    end

    it "reports zero for a game with no files rather than nil" do
      expect(GameFile.storage_used_by(create_game)).to eq(0)
    end

    it "does not count another game's files" do
      create_game_file(:game => create_game, :byte_size => 9_999_999)

      expect(GameFile.storage_used_by(@game)).to eq(0)
    end
  end

  it "is destroyed with its game" do
    create_game_file(:game => @game)

    expect { @game.destroy }.to change { GameFile.count }.by(-1)
  end
end
