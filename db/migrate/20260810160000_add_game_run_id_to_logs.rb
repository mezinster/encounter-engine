# Phase 2: a log states which RUNNING of a game it belongs to.
#
# Deriving it instead -- team + game -> passing -> run -- is unambiguous only
# while a game has one run. Phase 3 lets a team hold a passing in two runs of
# one game, and the join then breaks exactly where it matters: an author
# watching run 2's live channel would see run 1's answers.
class AddGameRunIdToLogs < ActiveRecord::Migration[8.0]
  def up
    add_column :logs, :game_run_id, :integer
    add_index  :logs, :game_run_id

    # Through the model, unlike phase 1's backfill. That one had to avoid Game
    # because Game#starts_at delegates to an autobuilt run and would have read
    # nil; nothing of the sort applies here -- Log has no delegation, and
    # reporting counts is worth more than shaving a query.
    counts = Log.backfill_run_ids!
    say "backfilled game_run_id on #{counts[:resolved]} log row(s)"
  end

  def down
    remove_column :logs, :game_run_id
  end
end
