require "rails_helper"

describe Log do
  describe ".backfill_passing_ids!" do
    it "resolves a scheduled log from its run and team" do
      level   = create_level
      passing = create_game_passing(:game => level.game, :level => level)
      log = Log.create!(:game_id => level.game.id, :team_id => passing.team_id,
                        :level_id => level.id, :game_run_id => passing.game_run_id,
                        :time => Time.now, :answer => "x")

      expect(Log.backfill_passing_ids!).to eq(:resolved => 1)
      expect(log.reload.game_passing_id).to eq(passing.id)
    end

    it "is idempotent" do
      level   = create_level
      passing = create_game_passing(:game => level.game, :level => level)
      Log.create!(:game_id => level.game.id, :team_id => passing.team_id,
                  :level_id => level.id, :game_run_id => passing.game_run_id,
                  :time => Time.now, :answer => "x")

      Log.backfill_passing_ids!
      expect(Log.backfill_passing_ids!).to eq(:resolved => 0)
    end

    it "leaves a log it cannot resolve alone" do
      level = create_level
      log = Log.create!(:game_id => level.game.id, :team_id => create_team.id,
                        :level_id => level.id, :time => Time.now, :answer => "x")

      Log.backfill_passing_ids!
      expect(log.reload.game_passing_id).to be_nil
    end
  end

  describe ".of_attempt" do
    it "returns only that attempt's rows" do
      level = create_level
      a = create_game_passing(:game => level.game, :level => level)
      b = create_game_passing(:game => level.game, :level => level)
      mine  = Log.create!(:game_id => level.game.id, :game_passing_id => a.id,
                          :time => Time.now, :answer => "mine")
      Log.create!(:game_id => level.game.id, :game_passing_id => b.id,
                  :time => Time.now, :answer => "theirs")

      expect(Log.of_attempt(a)).to eq([ mine ])
    end
  end
end
