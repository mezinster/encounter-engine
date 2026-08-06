class AddPenaltySecondsToGamePassings < ActiveRecord::Migration[8.0]
  def change
    # Accrues separately from current_level_entered_at, deliberately: that
    # column is the sole input to hint countdowns, so charging a penalty
    # against it would bring the next hint CLOSER on a wrong answer.
    add_column :game_passings, :penalty_seconds, :integer, null: false, default: 0
  end
end
