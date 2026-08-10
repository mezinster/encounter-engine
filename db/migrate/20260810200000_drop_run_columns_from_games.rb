# Deploy 2 of the game-runs programme: the CONTRACT half. Phase 1 created and
# backfilled game_runs and dropped nothing, so reverting the application code
# was a complete rollback with these eight columns still populated. This
# removes them, and with them that escape hatch -- after this migration the
# pre-phase-1 code no longer boots.
#
# See docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md §6.
class DropRunColumnsFromGames < ActiveRecord::Migration[8.0]
  # Named once so up and down cannot disagree about the set.
  COLUMNS = {
    :starts_at             => { :type => :datetime, :options => { :precision => nil } },
    :registration_deadline => { :type => :datetime, :options => { :precision => nil } },
    :max_team_number       => { :type => :integer,  :options => {} },
    :requested_teams_number => { :type => :integer, :options => { :default => 0 } },
    :author_finished_at    => { :type => :datetime, :options => { :precision => nil } },
    :is_testing            => { :type => :boolean,  :options => { :default => false, :null => false } },
    :test_date             => { :type => :datetime, :options => { :precision => nil } },
    :paused_at             => { :type => :datetime, :options => {} }
  }.freeze

  def up
    # PRE-FLIGHT, AND THE REASON THIS MIGRATION IS NOT A BARE drop_column.
    #
    # A game with no run has its schedule ONLY in these columns. Dropping them
    # destroys it with nothing to read it back from -- and the application
    # would not even error, because Game#current_run autobuilds an empty run,
    # so the game would simply come back with a blank schedule. Phase 1's
    # backfill gave every game a run; this refuses rather than trusts that.
    orphans = select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM games
       WHERE NOT EXISTS (SELECT 1 FROM game_runs WHERE game_runs.game_id = games.id)
    SQL

    if orphans > 0
      raise "#{orphans} game(s) have no game_runs row; dropping these columns " \
            "would destroy their schedule irrecoverably. Backfill first."
    end

    COLUMNS.each_key { |column| remove_column :games, column }
  end

  # Structurally reversible, and worth having: it is what turns "the old image
  # no longer boots" from permanent into a recovery procedure.
  #
  # It is NOT a faithful inverse, and cannot be. A game that has had several
  # runs collapses to run 1 -- the ordinal these columns held before phase 1 --
  # so a reinstated game comes back with its FIRST schedule, not its latest.
  # That is the closest thing to the pre-phase-1 shape that exists, and it is
  # the shape the pre-phase-1 code expects to read.
  def down
    COLUMNS.each do |column, spec|
      add_column :games, column, spec[:type], **spec[:options]
    end

    # Correlated subquery rather than UPDATE ... FROM, for the same reason
    # phase 1's backfill used one: SQLite (dev/test) and PostgreSQL
    # (production) disagree on that syntax.
    COLUMNS.each_key do |column|
      execute <<~SQL
        UPDATE games
           SET #{column} = (SELECT gr.#{column} FROM game_runs gr
                             WHERE gr.game_id = games.id AND gr.ordinal = 1)
         WHERE EXISTS (SELECT 1 FROM game_runs gr
                        WHERE gr.game_id = games.id AND gr.ordinal = 1)
      SQL
    end
  end
end
