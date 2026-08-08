class BackfillLogTeamAndLevelIds < ActiveRecord::Migration[8.0]
  def up
    counts = Log.backfill_ids!
    say "backfilled #{counts[:teams]} team_id and #{counts[:levels]} level_id values"
    say "left #{counts[:ambiguous]} row(s) NULL: their level name is ambiguous within its own game"
    say "logs still missing level_id: #{Log.where(:level_id => nil).count}"
    say "logs still missing team_id:  #{Log.where(:team_id => nil).count}"
  end

  # Genuinely reversible: this clears only the two columns the previous
  # migration (20260808060240_add_team_and_level_ids_to_logs.rb) added, and no
  # other code path writes to them yet (Task 3 still name-based scopes).
  def down
    Log.update_all(:team_id => nil, :level_id => nil)
  end
end
