class AddLocksToGames < ActiveRecord::Migration[8.0]
  def change
    # Timestamps rather than booleans: the console shows WHEN, which is what an
    # operator wants while investigating. Nullable, so no existing row changes.
    add_column :games, :editing_locked_at, :datetime
    add_column :games, :withdrawn_at,      :datetime
  end
end
