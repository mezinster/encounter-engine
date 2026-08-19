require "rails_helper"

describe GamePassing do
  let(:captain) { create_user }

  def skippable_game(attrs = {})
    game = create_game({ :max_skips => 2, :skip_points_fine => 25,
                         :points_enabled => true, :level_completion_points => 10 }.merge(attrs))
    one  = create_level(:game => game, :position => 1)
    two  = create_level(:game => game, :position => 2)
    [ game, one, two ]
  end

  describe "#skips_left" do
    it "starts at the game's cap and falls as skips are taken" do
      game, one, _two = skippable_game
      passing = create_game_passing(:game => game, :level => one)

      expect(passing.skips_left).to eq(2)
      passing.skip_level!(captain)
      expect(passing.reload.skips_left).to eq(1)
    end

    # The cap is DERIVED from the ledger, not stored. Removing the row is the
    # only way to demonstrate that -- against a stored counter this example
    # fails.
    it "is restored when the row behind it goes away" do
      game, one, _two = skippable_game
      passing = create_game_passing(:game => game, :level => one)
      passing.skip_level!(captain)

      PointTransaction.where(:game_passing_id => passing.id,
                             :reason => "level_skipped").delete_all

      expect(passing.reload.skips_left).to eq(2)
    end
  end

  describe "#skip_level!" do
    it "advances the team and charges the fine as a negative row" do
      game, one, two = skippable_game
      passing = create_game_passing(:game => game, :level => one)

      passing.skip_level!(captain)

      expect(passing.reload.current_level).to eq(two)
      row = PointTransaction.find_by(:game_passing_id => passing.id, :reason => "level_skipped")
      expect(row.amount).to eq(-25)
      expect(row.level_id).to eq(one.id)
    end

    it "awards nothing for the level it skipped" do
      game, one, _two = skippable_game
      passing = create_game_passing(:game => game, :level => one)

      passing.skip_level!(captain)

      expect(PointTransaction.where(:game_passing_id => passing.id,
                                    :reason => "level_completed").count).to eq(0)
    end

    # S3: the award is withheld only when the FINISHING action was a skip.
    it "pays no completion award when the skip ended the run" do
      game, _one, two = skippable_game
      passing = create_game_passing(:game => game, :level => two)

      passing.skip_level!(captain)

      expect(passing.reload.finished_at).not_to be_nil
      expect(PointTransaction.where(:game_passing_id => passing.id,
                                    :reason => "game_completed").count).to eq(0)
    end

    it "still pays the completion award when an earlier level was skipped but the last was played" do
      game, one, _two = skippable_game
      passing = create_game_passing(:game => game, :level => one)

      passing.skip_level!(captain)
      passing.pass_level!

      expect(PointTransaction.where(:game_passing_id => passing.id,
                                    :reason => "game_completed").count).to eq(1)
    end

    it "charges the time penalty onto penalty_seconds" do
      game, one, _two = skippable_game(:skip_time_penalty => 600)
      passing = create_game_passing(:game => game, :level => one)

      expect { passing.skip_level!(captain) }
        .to change { passing.reload.penalty_seconds.to_i }.by(600)
    end

    it "refuses once the cap is spent" do
      game, one, two = skippable_game(:max_skips => 1)
      passing = create_game_passing(:game => game, :level => one)
      passing.skip_level!(captain)
      expect(passing.reload.current_level).to eq(two)

      expect { passing.skip_level!(captain) }.to raise_error(ArgumentError)
    end

    it "refuses when the game allows no skips at all" do
      game, one, _two = skippable_game(:max_skips => 0)
      passing = create_game_passing(:game => game, :level => one)

      expect { passing.skip_level!(captain) }.to raise_error(ArgumentError)
    end

    it "records who did it" do
      game, one, _two = skippable_game
      passing = create_game_passing(:game => game, :level => one)

      passing.skip_level!(captain)

      row = PointTransaction.find_by(:game_passing_id => passing.id, :reason => "level_skipped")
      expect(row.created_by_id).to eq(captain.id)
    end
  end

  # S5. This is the example the whole ordering argument rests on. It must fail
  # if charge_skip! and advance! are swapped.
  describe "charging before advancing" do
    it "leaves the team on their level when the fine cannot be written" do
      game, one, _two = skippable_game
      passing = create_game_passing(:game => game, :level => one)

      allow(PointTransaction).to receive(:award!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { passing.skip_level!(captain) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(passing.reload.current_level).to eq(one)
    end

    # The self-heal: charged, advance failed, team retries. The partial unique
    # index refuses the second row, award! returns nil, and the advance runs.
    it "does not charge twice when a retry follows a failed advance" do
      game, one, two = skippable_game
      passing = create_game_passing(:game => game, :level => one)

      allow(passing).to receive(:advance!).and_raise(ActiveRecord::StatementInvalid, "boom")
      expect { passing.skip_level!(captain) }.to raise_error(ActiveRecord::StatementInvalid)

      allow(passing).to receive(:advance!).and_call_original
      passing.skip_level!(captain)

      expect(passing.reload.current_level).to eq(two)
      expect(PointTransaction.where(:game_passing_id => passing.id,
                                    :reason => "level_skipped").count).to eq(1)
    end
  end

  it "writes a log line so the level log shows what happened" do
    game, one, _two = skippable_game
    passing = create_game_passing(:game => game, :level => one)

    expect { passing.skip_level!(captain) }
      .to change { Log.where(:game_passing_id => passing.id).count }.by(1)
  end

  # A testing run writes its skip rows on purpose, and this is the one place
  # D2's rule and D1's diverge. Both halves in ONE example: an example covering
  # only the skip would pass against code that had dropped the testing gate
  # from awarding as well.
  describe "in a testing run" do
    it "records the skip and enforces the cap, while still awarding nothing" do
      game, one, _two = skippable_game
      game.current_run.update!(:is_testing => true)
      passing = create_game_passing(:game => game, :level => one)

      passing.skip_level!(captain)
      passing.pass_level!

      rows = PointTransaction.where(:game_passing_id => passing.id)
      expect(rows.where(:reason => "level_skipped").count).to eq(1)
      expect(rows.where(:reason => "level_completed").count).to eq(0)
      expect(passing.reload.skips_left).to eq(1)
    end
  end

  # S7: the points_enabled gate belongs to AWARDS, not to records of a team's
  # own action. Both halves in one example on purpose -- an example covering
  # only the skip half would pass against code that had dropped the gate from
  # awarding too.
  describe "with points disabled" do
    it "still records the skip and still enforces the cap, while awarding nothing" do
      game, one, _two = skippable_game(:points_enabled => false, :skip_points_fine => 0)
      passing = create_game_passing(:game => game, :level => one)

      passing.skip_level!(captain)
      passing.pass_level!

      rows = PointTransaction.where(:game_passing_id => passing.id)
      expect(rows.where(:reason => "level_skipped").count).to eq(1)
      expect(rows.where(:reason => "level_skipped").first.amount).to eq(0)
      expect(rows.where(:reason => "level_completed").count).to eq(0)
      expect(passing.reload.skips_left).to eq(1)
    end
  end
end
