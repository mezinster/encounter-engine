# An append-only ledger. Rows are written and never updated or reversed -- see
# the design, P3 -- which is why there is no updated_at: omitting it makes
# that structural rather than conventional.
class CreatePointTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :point_transactions do |t|
      t.integer  :team_id,         :null => false
      t.integer  :game_id,         :null => false
      t.integer  :game_passing_id, :null => false
      # Nullable: game_completed is not about a level.
      t.integer  :level_id
      # Signed. A deduction is a negative row, so a balance is one SUM and
      # never a case statement -- see the design, P6.
      t.integer  :amount,          :null => false
      t.string   :reason,          :null => false
      # An award earned by play has no actor; an operator adjustment would.
      # Nothing writes this yet -- see the design, §2.1.
      t.integer  :created_by_id
      t.datetime :created_at,      :null => false
    end

    # TWO partial unique indexes, not one, and the reason is a NULL.
    #
    # game_completed carries a nil level_id, and SQL compares NULLs as
    # DISTINCT in a unique index -- so a single index on
    # (game_passing_id, level_id, reason) would refuse a duplicate level award
    # and silently permit a duplicate completion award.
    add_index :point_transactions, [ :game_passing_id, :level_id, :reason ],
              :unique => true, :where => "level_id IS NOT NULL",
              :name => "index_point_transactions_per_level"
    add_index :point_transactions, [ :game_passing_id, :reason ],
              :unique => true, :where => "level_id IS NULL",
              :name => "index_point_transactions_per_attempt"

    add_index :point_transactions, :team_id
  end
end
