class AddScoringToGamesAndLevels < ActiveRecord::Migration[8.0]
  def change
    # Off by default: no existing game starts writing ledger rows behind its
    # author's back. See the design, P1.
    add_column :games, :points_enabled,          :boolean, :default => false, :null => false
    add_column :games, :level_completion_points, :integer, :default => 0,     :null => false
    add_column :games, :game_completion_points,  :integer, :default => 0,     :null => false

    # Nullable ON PURPOSE: nil means "use the game's value", 0 means zero.
    # An author must be able to make one level worth nothing without turning
    # scoring off for the whole game.
    add_column :levels, :points_award, :integer
  end
end
