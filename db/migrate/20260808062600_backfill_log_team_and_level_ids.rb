class BackfillLogTeamAndLevelIds < ActiveRecord::Migration[8.0]
  def up
    counts = Log.backfill_ids!
    say "backfilled #{counts[:teams]} team_id and #{counts[:levels]} level_id values"
    say "left #{counts[:ambiguous]} row(s) NULL: their level name is ambiguous within its own game"
    say "logs still missing level_id: #{Log.where(:level_id => nil).count}"
    say "logs still missing team_id:  #{Log.where(:team_id => nil).count}"
  end

  # NOT reversible. This was written when true: at the time, no other code
  # path wrote to team_id/level_id (Task 3 still had name-based scopes), so
  # clearing them just undid this migration's own backfill. That stopped
  # being true once save_log started writing both ids on every new row --
  # in an earlier commit than this migration, so by the time this migration
  # runs in production the app is already populating the columns live.
  # db:rollback would now wipe ids written by real gameplay, not just
  # backfilled ones, and under Log.of_team/of_level's id-only scopes (Task 4,
  # app/models/log.rb) every log row would vanish from all three author
  # views until re-backfilled -- and re-running `up` only recovers what
  # resolves unambiguously, not what was wiped.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
