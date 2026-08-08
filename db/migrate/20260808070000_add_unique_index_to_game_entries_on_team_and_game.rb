class AddUniqueIndexToGameEntriesOnTeamAndGame < ActiveRecord::Migration[8.0]
  # Scoped to the "live" statuses (see GameEntriesController and Game#free_
  # place_of_team!/reserve_place_for_team!, which treat exactly these two as
  # occupying a slot) rather than a blanket unique index on every row. A
  # blanket index would also reject legitimate history: an entry an author
  # rejected, followed by a later entry for the same team that was accepted
  # -- the exact shape GameEntry.of's comment documents and
  # spec/requests/game_registration_enforcement_spec.rb pins ("admits a team
  # whose earlier entry was rejected and later entry accepted"). This index
  # leaves that pattern alone and only forbids two simultaneously-live rows
  # for one (team_id, game_id) -- which is the actual bug: a double-clicked
  # "apply"/"reopen", or two near-simultaneous requests, creating or
  # reviving a second live entry while the first is still active.
  LIVE_STATUSES = %w[new accepted].freeze

  # Verified against production directly (2026-08-08): zero (team_id,
  # game_id) pairs with more than one live-status row, so this index is safe
  # to add today. But migrations run automatically via
  # bin/docker-entrypoint's `db:prepare` before puma starts, so letting
  # add_index raise outright on unexpected duplicate data would take the
  # whole app down with an opaque uniqueness-constraint error, mid-deploy,
  # recoverable only by someone shelling in to clean the table by hand.
  # Check first instead: if duplicates are ever found (a future backfill, a
  # restored-from-backup dataset -- anything other than today's known-clean
  # production), skip adding the index and say exactly which pairs collided,
  # so the deploy still succeeds and the app stays up. It is unprotected
  # against this specific race until someone resolves the duplicates and
  # re-runs this migration, but up.
  def up
    duplicates = GameEntry.where(:status => LIVE_STATUSES)
                           .group(:team_id, :game_id)
                           .having("COUNT(*) > 1")
                           .count

    if duplicates.any?
      say "SKIPPED: #{duplicates.size} (team_id, game_id) pair(s) have more than one " \
          "live-status (#{LIVE_STATUSES.join(', ')}) game_entries row -- unique index " \
          "NOT added. Resolve the duplicates (e.g. recall/reject all but one live entry " \
          "per pair) and re-run this migration. Pairs: #{duplicates.keys.inspect}"
    else
      add_index :game_entries, [:team_id, :game_id],
                unique: true,
                where: "status IN ('new', 'accepted')",
                name: "index_game_entries_on_team_id_and_game_id_live"
      say "added unique index on game_entries (team_id, game_id) for live statuses"
    end
  end

  def down
    remove_index :game_entries,
                 name: "index_game_entries_on_team_id_and_game_id_live",
                 if_exists: true
  end
end
