class CreateAccessPasses < ActiveRecord::Migration[8.0]
  def change
    create_table :access_passes do |t|
      t.integer  :game_id,      :null => false
      t.integer  :team_id,      :null => false
      t.string   :source,       :null => false
      t.integer  :issued_by_id
      t.datetime :revoked_at
      t.timestamps
    end

    # Deliberately NOT unique: a team may hold several passes for one game,
    # consumed oldest first. See the design, B6 -- liveness is derived from
    # the attempt, so no index could enforce "one live pass" anyway.
    add_index :access_passes, [ :game_id, :team_id ]

    # The 1:1 binding lives in the same migration as the table it binds,
    # because AccessPass#spent? reads through it -- a pass model without this
    # column has no testable behaviour at all.
    #
    # Written explicitly rather than leaning on the existing
    # (team_id, game_run_id) index, which stops constraining commercial rows
    # only because SQL compares NULLs as distinct -- true, but implicit.
    add_column :game_passings, :access_pass_id, :integer
    add_index  :game_passings, :access_pass_id,
               :unique => true, :where => "access_pass_id IS NOT NULL"
  end
end
