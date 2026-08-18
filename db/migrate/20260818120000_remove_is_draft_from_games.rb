class RemoveIsDraftFromGames < ActiveRecord::Migration[8.0]
  def up
    remove_column :games, :is_draft
  end

  def down
    add_column :games, :is_draft, :boolean, :default => false, :null => false
    # TRUE/FALSE, not 1/0: SQLite has no real boolean type and accepts either,
    # but PostgreSQL -- production -- rejects an integer literal against a
    # boolean column outright. Finding 8 of the whole-branch review.
    execute "UPDATE games SET is_draft = CASE WHEN visibility = 'draft' THEN TRUE ELSE FALSE END"
  end
end
