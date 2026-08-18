class RemoveIsDraftFromGames < ActiveRecord::Migration[8.0]
  def up
    remove_column :games, :is_draft
  end

  def down
    add_column :games, :is_draft, :boolean, :default => false, :null => false
    execute "UPDATE games SET is_draft = CASE WHEN visibility = 'draft' THEN 1 ELSE 0 END"
  end
end
