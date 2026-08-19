require "rails_helper"

# These pin what pass_level! does, so the extraction underneath it is provably
# a refactor. They are written against pass_level!, NOT against advance!,
# because the point is that the public behaviour is unchanged.
describe GamePassing do
  describe "#pass_level! advancing" do
    let(:game)  { create_game }
    let(:one)   { create_level(:game => game, :position => 1) }
    let(:two)   { create_level(:game => game, :position => 2) }

    it "moves to the next level and restamps the level clock" do
      one and two
      passing = create_game_passing(:game => game, :level => one)
      passing.update!(:current_level_entered_at => 2.hours.ago)

      passing.pass_level!

      expect(passing.reload.current_level).to eq(two)
      expect(passing.current_level_entered_at).to be > 1.minute.ago
      expect(passing.finished_at).to be_nil
    end

    it "finishes on the last level instead of restamping the clock" do
      one and two
      passing = create_game_passing(:game => game, :level => two)

      passing.pass_level!

      expect(passing.reload.finished_at).not_to be_nil
      expect(passing.current_level).to be_nil
    end

    it "clears answered questions on the way" do
      one and two
      question = create_question(:level => one)
      passing  = create_game_passing(:game => game, :level => one)
      passing.pass_question!(question)
      expect(passing.answered_questions).not_to be_empty

      passing.pass_level!

      expect(passing.reload.answered_questions).to be_empty
    end

    it "clears answered questions on the finishing path too" do
      one and two
      question = create_question(:level => two)
      passing  = create_game_passing(:game => game, :level => two)
      passing.pass_question!(question)
      expect(passing.answered_questions).not_to be_empty

      passing.pass_level!

      passing.reload
      expect(passing.finished_at).not_to be_nil
      expect(passing.answered_questions).to be_empty
    end
  end
end
