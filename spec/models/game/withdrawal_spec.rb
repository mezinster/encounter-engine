require "rails_helper"

describe Game do
  # A game that is actually being played -- withdrawal exists for these, and a
  # started game does not pass its own validations, which is why withdraw! and
  # pause! both use update_column.
  def running_game
    game = create_game
    create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game.reload
  end

  describe "#withdraw! with freeze" do
    it "records the reason and the mode" do
      game = running_game

      game.withdraw!(:category => "technical", :note => "Код на точке 4 неверный",
                     :mode => "freeze")

      game.reload
      expect(game.withdrawn?).to be true
      expect(game.withdrawal_category).to eq("technical")
      expect(game.withdrawal_note).to eq("Код на точке 4 неверный")
      expect(game.withdrawal_mode).to eq("freeze")
    end

    it "pauses a run that was not paused, and says that it did" do
      game = running_game
      expect(game.paused?).to be false

      game.withdraw!(:category => "weather", :mode => "freeze")

      expect(game.reload.paused?).to be true
      expect(game.withdrawal_paused_run).to be true
    end

    # The overlap that needs care: pause and withdrawal are independent states.
    it "leaves an already paused run alone, and does not claim it paused it" do
      game = running_game
      game.pause!
      paused_at = game.current_run.reload.paused_at

      game.withdraw!(:category => "safety", :mode => "freeze")

      expect(game.reload.withdrawal_paused_run).to be false
      expect(game.current_run.reload.paused_at.to_i).to eq(paused_at.to_i)
    end

    it "leaves runs in progress" do
      game    = running_game
      passing = create_game_passing(:level => game.levels.first)

      game.withdraw!(:category => "technical", :mode => "freeze")

      expect(passing.reload.status).to be_nil
      expect(passing.current_level).not_to be_nil
    end
  end

  describe "#withdraw! and end" do
    it "ends every run in progress" do
      game    = running_game
      passing = create_game_passing(:level => game.levels.first)

      game.withdraw!(:category => "cancelled", :mode => "ended")

      expect(passing.reload.status).to eq("ended")
      expect(game.reload.withdrawn?).to be true
    end

    it "does not pause the run" do
      game = running_game

      game.withdraw!(:category => "cancelled", :mode => "ended")

      expect(game.reload.paused?).to be false
      expect(game.withdrawal_paused_run).to be false
    end
  end

  describe "#withdraw! refusals" do
    it "refuses an unknown category" do
      game = running_game
      expect { game.withdraw!(:category => "banana", :mode => "freeze") }
        .to raise_error(ArgumentError)
      expect(game.reload.withdrawn?).to be false
    end

    it "refuses an unknown mode" do
      game = running_game
      expect { game.withdraw!(:category => "technical", :mode => "sideways") }
        .to raise_error(ArgumentError)
      expect(game.reload.withdrawn?).to be false
    end
  end

  describe "#restore!" do
    it "clears every withdrawal column" do
      game = running_game
      game.withdraw!(:category => "weather", :note => "Гроза", :mode => "freeze")

      game.restore!

      game.reload
      expect(game.withdrawn?).to be false
      expect(game.withdrawal_category).to be_nil
      expect(game.withdrawal_note).to be_nil
      expect(game.withdrawal_mode).to be_nil
      expect(game.withdrawal_paused_run).to be false
    end

    it "resumes a run the withdrawal paused" do
      game = running_game
      game.withdraw!(:category => "weather", :mode => "freeze")

      game.restore!

      expect(game.reload.paused?).to be false
    end

    # The other half of the overlap: an operator who paused BEFORE withdrawing
    # expects the game to still be paused after restoring.
    it "leaves a pause the operator made themselves" do
      game = running_game
      game.pause!
      game.withdraw!(:category => "safety", :mode => "freeze")

      game.restore!

      expect(game.reload.paused?).to be true
    end

    it "does not revive ended runs" do
      game    = running_game
      passing = create_game_passing(:level => game.levels.first)
      game.withdraw!(:category => "cancelled", :mode => "ended")

      game.restore!

      expect(passing.reload.status).to eq("ended")
    end
  end
end
