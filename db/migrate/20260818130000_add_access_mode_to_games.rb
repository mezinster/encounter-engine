class AddAccessModeToGames < ActiveRecord::Migration[8.0]
  def change
    add_column :games, :access_mode, :string, :default => "scheduled", :null => false
  end
end
