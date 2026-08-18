class AddGamePassingToLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :logs, :game_passing_id, :integer
    add_index  :logs, :game_passing_id

    # Log's schema cache was loaded before this migration ran, so without
    # this the model may not know the column it was just given -- backfill_
    # passing_ids! would then try to set an attribute Log doesn't think
    # exists. Finding 9 of the whole-branch review.
    Log.reset_column_information

    resolved = Log.backfill_passing_ids!
    say "backfilled game_passing_id on #{resolved[:resolved]} log rows"
  end

  def down
    remove_column :logs, :game_passing_id
  end
end
