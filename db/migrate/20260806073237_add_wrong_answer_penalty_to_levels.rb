class AddWrongAnswerPenaltyToLevels < ActiveRecord::Migration[8.0]
  def change
    # Seconds, set per level by the author. 0 means guessing is free, which is
    # the behaviour of every level that exists.
    add_column :levels, :wrong_answer_penalty, :integer, null: false, default: 0
  end
end
