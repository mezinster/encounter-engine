require "rails_helper"

describe Game do
  describe "#visibility" do
    it "defaults a new game to draft" do
      expect(Game.new.visibility).to eq("draft")
    end

    it "refuses a value outside the enum" do
      game = create_game
      game.visibility = "hidden"
      expect(game).not_to be_valid
      expect(game.errors[:visibility]).to be_present
    end

    it "reports draft? from the column" do
      game = create_game
      game.update!(:visibility => "draft")
      expect(game.reload.draft?).to be true
      expect(game.listed?).to be false
    end

    it "reports listed? from the column" do
      game = create_game
      game.update!(:visibility => "listed")
      expect(game.reload.listed?).to be true
      expect(game.draft?).to be false
    end
  end

  describe ".visible" do
    it "excludes a draft" do
      game = create_game(:is_draft => true)
      expect(Game.visible).not_to include(game)
    end

    it "includes a listed game" do
      game = create_game(:is_draft => false)
      expect(Game.visible).to include(game)
    end

    # Orthogonal to visibility, and deliberately still its own column --
    # see the design, B2a.
    it "excludes a listed game that has been withdrawn" do
      game = create_game(:is_draft => false)
      game.withdraw!
      expect(Game.visible).not_to include(game)
    end
  end
end
