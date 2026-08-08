class AddActorLabelToAdminActions < ActiveRecord::Migration[8.0]
  # The mirror of target_label, and it exists for the same reason its comment
  # gives: an id nobody can resolve is the worst possible audit outcome.
  #
  # actor_id is null: false in the schema but optional: true in the model, and
  # app/views/admin/audit/index.html.erb already renders «неизвестно» when the
  # actor is missing -- so deleting an operator turns every action they ever
  # took into an unattributable row, in a log this codebase documents as
  # append-only. Deleting the subject is a way of editing the log.
  #
  # Added before anything can delete a user, so no history is lost while it
  # waits.
  def up
    add_column :admin_actions, :actor_label, :string

    # Backfilled in the same migration rather than left to new rows: every
    # existing entry has a resolvable actor TODAY, and that is the only moment
    # the snapshot can still be taken.
    filled = 0
    AdminAction.reset_column_information
    AdminAction.includes(:actor).find_each do |entry|
      nickname = entry.actor&.nickname
      next if nickname.nil?

      entry.update_columns(:actor_label => nickname)
      filled += 1
    end

    say "backfilled actor_label on #{filled} of #{AdminAction.count} admin_actions"
    say "left #{AdminAction.where(:actor_label => nil).count} row(s) NULL: their actor no longer resolves"
  end

  def down
    remove_column :admin_actions, :actor_label
  end
end
