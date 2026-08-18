require "rails_helper"

describe Game do
  it "defaults to the scheduled mode" do
    expect(Game.new.access_mode).to eq("scheduled")
    expect(Game.new.pass_required?).to be false
  end

  it "refuses a value outside the enum" do
    game = create_game
    game.access_mode = "invitation"
    expect(game).not_to be_valid
    expect(game.errors[:access_mode]).to be_present
  end

  it "reports pass_required? from the column" do
    game = create_game
    game.update!(:access_mode => "pass_required")
    expect(game.reload.pass_required?).to be true
  end

  describe "#status" do
    # The ladder is positional and the two definitions of it -- this method
    # and count_by_status -- must agree. See the design, §7.
    it "reports :available for a listed gated game" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      expect(game.status).to eq(:available)
    end

    it "still reports :draft for a gated game that is not published" do
      game = create_game(:is_draft => true, :access_mode => "pass_required")
      expect(game.status).to eq(:draft)
    end

    it "still reports :withdrawn for a gated game that was withdrawn" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      game.withdraw!
      expect(game.status).to eq(:withdrawn)
    end

    it "reports :finished for a gated game the author has closed" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      game.finish_game!
      expect(game.reload.status).to eq(:finished)
    end

    it "leaves a scheduled game's status untouched" do
      game = create_game(:is_draft => false)
      expect(game.status).to eq(:scheduled)
    end
  end

  describe ".count_by_status" do
    # If this and #status disagree, the operator dashboard and the catalog
    # label the same game differently -- the exact failure the design warns
    # about, and one this codebase has shipped before.
    it "counts a listed gated game as available, not scheduled" do
      create_game(:is_draft => false, :access_mode => "pass_required")
      counts = Game.count_by_status
      expect(counts[:available]).to eq(1)
      expect(counts[:scheduled]).to eq(0)
    end

    it "agrees with #status for every game it counts" do
      create_game(:is_draft => false, :access_mode => "pass_required")
      create_game(:is_draft => false)
      create_game(:is_draft => true)

      counts = Game.count_by_status
      Game.find_each do |game|
        expect(counts[game.status]).to be >= 1
      end
    end
  end
end
