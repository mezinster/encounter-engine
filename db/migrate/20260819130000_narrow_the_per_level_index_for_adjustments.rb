class NarrowThePerLevelIndexForAdjustments < ActiveRecord::Migration[8.0]
  def change
    # The per-ATTEMPT index was narrowed for adjustments when they were added;
    # this one was missed. Nothing writes a level-scoped adjustment today --
    # PointTransaction.adjust! always sets level_id nil -- so the gap is
    # unreachable, which is exactly what makes it worth closing now: the
    # deferred level-scoped adjustment (design section 8) would hit
    # RecordNotUnique on its second row, and adjust! deliberately does not
    # rescue, so a person would get a 500 rather than a second adjustment.
    #
    # level_completed and level_skipped keep their idempotence: they are the
    # reasons this index exists for, and both are still covered.
    remove_index :point_transactions,
                 :column => [ :game_passing_id, :level_id, :reason ],
                 :name   => "index_point_transactions_per_level",
                 :unique => true,
                 :where  => "level_id IS NOT NULL"

    add_index :point_transactions, [ :game_passing_id, :level_id, :reason ],
              :unique => true,
              :where  => "level_id IS NOT NULL AND reason <> 'adjustment'",
              :name   => "index_point_transactions_per_level"
  end
end
