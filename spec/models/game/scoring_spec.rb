require "rails_helper"

describe Game do
  describe "scoring configuration" do
    it "is off by default, and awards nothing" do
      game = create_game
      expect(game.points_enabled).to be false
      expect(game.level_completion_points).to eq(0)
      expect(game.game_completion_points).to eq(0)
    end
  end

  describe "the award settings refuse negative values" do
    # :min => 0 on the form is client-side only. A crafted POST would otherwise
    # make every team that passes a level LOSE points automatically, silently,
    # for the whole game -- which is not a fine anyone chose to issue. Two
    # mechanisms already exist for deliberate deductions: D2's skip fine and
    # D3's operator adjustment, both signed on purpose.
    it "refuses a negative award for a level" do
      game = create_game
      game.level_completion_points = -5
      expect(game).not_to be_valid
      expect(game.errors[:level_completion_points]).not_to be_empty
    end

    it "refuses a negative award for finishing" do
      game = create_game
      game.game_completion_points = -5
      expect(game).not_to be_valid
      expect(game.errors[:game_completion_points]).not_to be_empty
    end

    it "still accepts zero for both" do
      expect(create_game(:level_completion_points => 0,
                         :game_completion_points => 0)).to be_valid
    end
  end

  describe "#points_for_level" do
    let(:game)  { create_game(:points_enabled => true, :level_completion_points => 10) }
    let(:level) { create_level(:game => game) }

    it "uses the game's default when the level sets none" do
      expect(level.points_award).to be_nil
      expect(game.points_for_level(level)).to eq(10)
    end

    it "uses the level's override when it is set" do
      level.update!(:points_award => 25)
      expect(game.points_for_level(level)).to eq(25)
    end

    # nil means "use the game's value"; 0 means zero. An author must be able
    # to make one level worth nothing without turning scoring off entirely.
    # Mutation-tested: this fails against any resolver that treats zero as
    # absent (`points_award.zero?`, `to_i > 0`, `&.positive?`). It does NOT
    # discriminate `||` from the explicit nil test -- 0 is truthy in Ruby, so
    # those two are the same program. See the comment on Game#points_for_level.
    it "treats an override of zero as zero, not as absent" do
      level.update!(:points_award => 0)
      expect(game.points_for_level(level)).to eq(0)
    end
  end
end
