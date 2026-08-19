require "rails_helper"

describe Game do
  describe "skip configuration" do
    it "is off by default and costs nothing" do
      game = create_game
      expect(game.max_skips).to eq(0)
      expect(game.skip_points_fine).to eq(0)
      expect(game.skip_time_penalty).to eq(0)
      expect(game.skips_allowed?).to be false
    end

    # max_skips IS the feature switch -- there is no separate boolean, so this
    # is the only thing that turns skipping on.
    it "is allowed once the author sets a cap" do
      expect(create_game(:max_skips => 2).skips_allowed?).to be true
    end

    # :min => 0 in the form is client-side only; a hand-crafted POST bypasses
    # it entirely, and a negative fine would PAY a team for skipping.
    it "refuses a negative fine" do
      game = create_game
      game.skip_points_fine = -5
      expect(game).not_to be_valid
      expect(game.errors[:skip_points_fine]).not_to be_empty
    end

    it "refuses a negative cap and a negative time penalty" do
      game = create_game
      game.max_skips = -1
      game.skip_time_penalty = -30
      expect(game).not_to be_valid
      expect(game.errors[:max_skips]).not_to be_empty
      expect(game.errors[:skip_time_penalty]).not_to be_empty
    end

    it "accepts zero for all three" do
      expect(create_game(:max_skips => 0, :skip_points_fine => 0,
                         :skip_time_penalty => 0)).to be_valid
    end
  end
end
