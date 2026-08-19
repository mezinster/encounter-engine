class AllowGlobalPointTransactions < ActiveRecord::Migration[8.0]
  def change
    # A team-global adjustment belongs to no run and no game.
    change_column_null :point_transactions, :game_passing_id, true
    change_column_null :point_transactions, :game_id, true

    # text, not string: an operator explaining a disputed penalty writes a few
    # sentences, and a 255-character ceiling would truncate exactly the
    # adjustments that most need explaining.
    add_column :point_transactions, :note, :text

    # The per-attempt index caps one row per (attempt, reason). That is what
    # makes an award idempotent, and it would cap adjustments at ONE PER
    # ATTEMPT forever. Narrow it rather than dropping it: level_completed,
    # game_completed and level_skipped all still depend on it.
    #
    # Global adjustments were never affected -- NULLs are distinct in a unique
    # index -- so without this change the feature would work for the rarer case
    # and silently refuse the commoner one, and work the first time in both.
    remove_index :point_transactions,
                 :column => [ :game_passing_id, :reason ],
                 :name   => "index_point_transactions_per_attempt",
                 :unique => true,
                 :where  => "level_id IS NULL"

    add_index :point_transactions, [ :game_passing_id, :reason ],
              :unique => true,
              :where  => "level_id IS NULL AND reason <> 'adjustment'",
              :name   => "index_point_transactions_per_attempt"
  end
end
