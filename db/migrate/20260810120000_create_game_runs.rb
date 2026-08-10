# Phase 1 of separating a game's CONTENT from one RUNNING of it. Expand only:
# this creates and backfills, and drops nothing, so reverting the application
# code is a complete rollback with the games columns still populated. Dropping
# them is a separate, later migration.
#
# See docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md.
class CreateGameRuns < ActiveRecord::Migration[8.0]
  def up
    create_table :game_runs do |t|
      t.integer  :game_id, :null => false
      t.integer  :ordinal, :null => false, :default => 1
      t.datetime :starts_at, :precision => nil
      t.datetime :registration_deadline, :precision => nil
      t.integer  :max_team_number
      t.integer  :requested_teams_number, :default => 0
      t.datetime :author_finished_at, :precision => nil
      t.boolean  :is_testing, :null => false, :default => false
      t.datetime :test_date, :precision => nil
      t.datetime :paused_at
      t.timestamps
    end

    add_column :game_passings, :game_run_id, :integer
    add_column :game_entries,  :game_run_id, :integer

    # RAW SQL, DELIBERATELY, AND THIS IS THE MOST DANGEROUS LINE IN THE PHASE.
    #
    # Once the application code lands, Game#starts_at delegates to current_run,
    # which AUTOBUILDS an empty run when none exists. So the obvious form --
    #
    #   Game.find_each { |g| g.runs.create!(:starts_at => g.starts_at) }
    #
    # -- reads starts_at THROUGH the delegation, off a freshly built empty run,
    # and copies nil into every row: every schedule in the database silently
    # destroyed, with the migration reporting success and the app booting fine.
    # Going straight at the table cannot do that.
    execute <<~SQL
      INSERT INTO game_runs (game_id, ordinal, starts_at, registration_deadline,
                             max_team_number, requested_teams_number,
                             author_finished_at, is_testing, test_date, paused_at,
                             created_at, updated_at)
      SELECT id, 1, starts_at, registration_deadline,
             max_team_number, requested_teams_number,
             author_finished_at, is_testing, test_date, paused_at,
             created_at, updated_at
        FROM games
    SQL

    # Correlated subquery rather than a JOIN in UPDATE: portable across SQLite
    # (dev/test) and PostgreSQL (production), which disagree on UPDATE ... FROM.
    #
    # game_passings.game_id is nullable (belongs_to :game, optional: true), so a
    # row with no game keeps a NULL game_run_id. That is correct, not a miss.
    execute <<~SQL
      UPDATE game_passings
         SET game_run_id = (SELECT gr.id FROM game_runs gr
                             WHERE gr.game_id = game_passings.game_id)
    SQL

    execute <<~SQL
      UPDATE game_entries
         SET game_run_id = (SELECT gr.id FROM game_runs gr
                             WHERE gr.game_id = game_entries.game_id)
    SQL

    add_index :game_runs, [ :game_id, :ordinal ], :unique => true
    add_index :game_passings, :game_run_id
    add_index :game_entries, :game_run_id
  end

  def down
    remove_column :game_entries, :game_run_id
    remove_column :game_passings, :game_run_id
    drop_table :game_runs
  end
end
