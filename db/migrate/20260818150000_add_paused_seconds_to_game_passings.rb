class AddPausedSecondsToGamePassings < ActiveRecord::Migration[8.0]
  def change
    add_column :game_passings, :paused_seconds, :integer, :default => 0, :null => false
  end
end
