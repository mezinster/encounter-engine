class AddGamePassingToLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :logs, :game_passing_id, :integer
    add_index  :logs, :game_passing_id

    resolved = Log.backfill_passing_ids!
    say "backfilled game_passing_id on #{resolved[:resolved]} log rows"
  end

  def down
    remove_column :logs, :game_passing_id
  end
end
