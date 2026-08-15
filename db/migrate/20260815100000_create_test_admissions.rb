# Who, besides the author's own team, may play one TESTING run.
#
# Run-scoped rather than game-scoped, matching GameEntry: a test is one
# running of the content, and an admission must not survive into the next.
class CreateTestAdmissions < ActiveRecord::Migration[8.0]
  def change
    create_table :test_admissions do |t|
      t.integer  :game_run_id, :null => false
      # Always present, for BOTH kinds of admission: the play path resolves a
      # team and nothing else, so a solo admission names the disposable team
      # created for it rather than deferring that work into a GET request.
      t.integer  :team_id, :null => false
      # NULL means "a real team, playing as itself". Non-null means "one
      # player, playing solo in the disposable team named above". The
      # nullability IS the type discriminator.
      t.integer  :user_id
      t.datetime :created_at, :null => false
    end

    add_index :test_admissions, [ :game_run_id, :team_id ], :unique => true,
              :name => "index_test_admissions_on_run_and_team"
    # Partial, and the WHERE clause is load-bearing: without it two team
    # admissions (both user_id NULL) collide on the second insert.
    add_index :test_admissions, [ :game_run_id, :user_id ], :unique => true,
              :where => "user_id IS NOT NULL",
              :name => "index_test_admissions_on_run_and_user"

    # The link credential for a test run. Written by start_test, nil'd by
    # finish_test, regenerable by the author (which revokes the old link).
    add_column :game_runs, :test_token, :string
    add_index  :game_runs, :test_token, :unique => true
  end
end
