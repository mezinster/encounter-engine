class AddPausedAtToGames < ActiveRecord::Migration[8.0]
  def change
    # Nullable: nil means "not paused", which is every game that exists.
    # Durable rather than in-memory, so a deploy or a crash mid-pause leaves
    # the game paused and resume works whenever someone reaches it.
    add_column :games, :paused_at, :datetime
  end
end
