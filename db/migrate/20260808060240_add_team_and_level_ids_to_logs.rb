class AddTeamAndLevelIdsToLogs < ActiveRecord::Migration[8.0]
  # Deliberately no foreign key constraints. Game#destroy currently orphans log
  # rows on purpose (see the comment on Game#deletable?), and a database-level
  # constraint would turn that into an exception. Whether logs should cascade is
  # a product decision, not part of this change.
  #
  # Both columns are nullable: the backfill cannot resolve a level name that is
  # ambiguous within its game, and level names have no uniqueness constraint.
  def change
    add_column :logs, :team_id,  :integer
    add_column :logs, :level_id, :integer

    # logs had no indexes at all -- not even on game_id -- while show_full_log
    # queries it once per (level x team) inside nested loops.
    add_index :logs, [ :game_id, :team_id, :level_id ]
  end
end
