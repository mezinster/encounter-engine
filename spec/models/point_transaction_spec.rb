require "rails_helper"

describe PointTransaction do
  let(:level)   { create_level }
  let(:game)    { level.game }
  let(:passing) { create_game_passing(:game => game, :level => level) }

  describe ".award!" do
    it "records a signed amount against the team, game and attempt" do
      row = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                    :level => level, :amount => 10)

      expect(row.team_id).to eq(passing.team_id)
      expect(row.game_id).to eq(game.id)
      expect(row.game_passing_id).to eq(passing.id)
      expect(row.level_id).to eq(level.id)
      expect(row.amount).to eq(10)
    end

    it "accepts a negative amount, because a deduction is a negative row" do
      row = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                    :level => level, :amount => -5)
      expect(row.amount).to eq(-5)
    end

    it "refuses an unknown reason" do
      expect {
        PointTransaction.award!(:passing => passing, :reason => "invented",
                                :level => level, :amount => 1)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  # Two guards, because game_completed carries a nil level_id and SQL compares
  # NULLs as DISTINCT -- one index would catch the level case and silently
  # miss the completion case. See the design, P5.
  describe "idempotency" do
    it "records a level award once per attempt" do
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)

      expect(PointTransaction.where(:reason => "level_completed").count).to eq(1)
    end

    # The one a single index would miss.
    it "records a completion award once per attempt" do
      PointTransaction.award!(:passing => passing, :reason => "game_completed",
                              :level => nil, :amount => 50)
      PointTransaction.award!(:passing => passing, :reason => "game_completed",
                              :level => nil, :amount => 50)

      expect(PointTransaction.where(:reason => "game_completed").count).to eq(1)
    end

    it "returns nil for the refused duplicate rather than raising" do
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      second = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                       :level => level, :amount => 10)

      expect(second).to be_nil
    end

    it "lets a different level in the same attempt be awarded" do
      other = create_level(:game => game)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => other, :amount => 10)

      expect(PointTransaction.count).to eq(2)
    end

    # A replay is a different attempt, so it earns its own awards.
    it "lets a second attempt at the same game be awarded" do
      second_attempt = create_game_passing(:game => game, :level => level)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => second_attempt, :reason => "level_completed",
                              :level => level, :amount => 10)

      expect(PointTransaction.count).to eq(2)
    end
  end

  describe "Team#balance" do
    it "is zero for a team with no transactions" do
      expect(create_team.balance).to eq(0)
    end

    it "sums signed amounts" do
      team = passing.team
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10)
      PointTransaction.award!(:passing => passing, :reason => "game_completed",
                              :level => nil, :amount => -3)

      expect(team.reload.balance).to eq(7)
    end
  end
end
