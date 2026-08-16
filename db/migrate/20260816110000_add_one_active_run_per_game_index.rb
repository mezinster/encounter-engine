# One active translation run per game, enforced by the database.
#
# The controller's check-then-act guard (TranslationRunsController#create:
# TranslationRun.active_for(@game).exists? followed by TranslationRun.create!)
# is necessary for the friendly message but cannot be sufficient: two
# concurrent POSTs -- a double-clicked button, two locale buttons in quick
# succession -- both pass it under Puma's multi-threaded default. What is at
# stake is not a duplicate row but a duplicate bill, because
# Runner#already_proposed? de-duplicates within a run, so a second run
# re-translates every field the first is already paying for.
#
# Partial index, not a plain unique index on game_id: a game legitimately
# accumulates many terminal (succeeded/failed/cancelled) runs over time, and
# only the active ones (pending/running) must be mutually exclusive.
#
# Partial indexes work on both SQLite (dev/test) and Postgres (production),
# so this is enforced everywhere, not just where a lock happens to be honoured.
class AddOneActiveRunPerGameIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :translation_runs, :game_id, :unique => true,
              :where => "state IN ('pending', 'running')",
              :name => "index_translation_runs_one_active_per_game"
  end
end
