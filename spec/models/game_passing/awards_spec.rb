require "rails_helper"

describe GamePassing do
  def scoring_game
    game = create_game(:points_enabled => true,
                       :level_completion_points => 10,
                       :game_completion_points => 50)
    first  = create_level(:game => game, :position => 1)
    second = create_level(:game => game, :position => 2)
    [ game, first, second ]
  end

  it "awards the level value on passing a level" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)

    expect { passing.pass_level! }.to change { PointTransaction.count }.by(1)

    row = PointTransaction.last
    expect(row.reason).to eq("level_completed")
    expect(row.amount).to eq(10)
    expect(row.level_id).to eq(first.id)
  end

  it "awards the level value AND the completion value on the last level" do
    game, _first, second = scoring_game
    passing = create_game_passing(:game => game, :level => second)

    expect { passing.pass_level! }.to change { PointTransaction.count }.by(2)

    expect(PointTransaction.where(:reason => "game_completed").first.amount).to eq(50)
    expect(PointTransaction.where(:reason => "game_completed").first.level_id).to be_nil
  end

  it "honours a per-level override" do
    game, first, _second = scoring_game
    first.update!(:points_award => 25)
    passing = create_game_passing(:game => game, :level => first)

    passing.pass_level!

    expect(PointTransaction.last.amount).to eq(25)
  end

  it "writes nothing at all when scoring is off" do
    game, first, _second = scoring_game
    game.update!(:points_enabled => false)
    passing = create_game_passing(:game => game, :level => first)

    expect { passing.pass_level! }.not_to change { PointTransaction.count }
  end

  # The idempotency guard, exercised the way it can actually fail: an operator
  # sends a team back and they pass the same level again.
  it "awards a level once even when the team is moved back and re-passes it" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)
    passing.pass_level!

    passing.move_to_level!(first)
    passing.pass_level!

    expect(PointTransaction.where(:reason => "level_completed", :level_id => first.id).count).to eq(1)
  end

  # The half a single index would miss.
  it "awards the completion once even when the attempt is completed twice" do
    game, _first, second = scoring_game
    passing = create_game_passing(:game => game, :level => second)
    passing.pass_level!

    passing.move_to_level!(second)
    passing.pass_level!

    expect(PointTransaction.where(:reason => "game_completed").count).to eq(1)
  end

  # P4: the ledger never reverses, so a team that quits keeps what it earned
  # and simply never earns the completion award. This is the example that
  # would catch anyone "tidying up" abandoned runs later.
  it "leaves earned points alone when the team abandons the run" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)
    passing.pass_level!

    expect { passing.exit! }.not_to change { PointTransaction.count }
    expect(passing.team.reload.balance).to eq(10)
    expect(PointTransaction.where(:reason => "game_completed").count).to eq(0)
  end

  # A team standing in a street with a correct answer must advance whether or
  # not the ledger accepts a row.
  it "still advances the team when the award is a duplicate" do
    game, first, _second = scoring_game
    passing = create_game_passing(:game => game, :level => first)
    passing.pass_level!
    passing.move_to_level!(first)

    passing.pass_level!

    expect(passing.reload.current_level_id).not_to eq(first.id)
  end

  # This is NOT redundant with "still advances ... duplicate" above: a
  # duplicate is rescued inside award! and returns nil, so it can never
  # distinguish an award called before the advance is saved from one called
  # after. Only a raising award proves the ordering -- that award_points_for
  # runs strictly after save!, so a ledger failure can never cost a team
  # their accepted answer. Asserted against a reload: an in-memory attribute
  # would still look advanced even if the save had been rolled back.
  it "advances the team even when the ledger write raises" do
    game, first, second = scoring_game
    passing = create_game_passing(:game => game, :level => first)
    allow(PointTransaction).to receive(:award!).and_raise(ActiveRecord::StatementInvalid, "boom")

    expect { passing.pass_level! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(passing.reload.current_level_id).to eq(second.id)
  end
end
