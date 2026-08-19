class AddSkippingToGames < ActiveRecord::Migration[8.0]
  def change
    # All three default to 0, and max_skips = 0 means "skipping is off". The
    # cap doubles as the feature switch deliberately -- a separate boolean
    # would be a second source of truth free to disagree with the number.
    add_column :games, :max_skips,          :integer, :null => false, :default => 0
    add_column :games, :skip_points_fine,   :integer, :null => false, :default => 0
    add_column :games, :skip_time_penalty,  :integer, :null => false, :default => 0
  end
end
