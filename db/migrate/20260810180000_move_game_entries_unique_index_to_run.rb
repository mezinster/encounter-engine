# The live-entry uniqueness moves from the GAME to the RUN.
#
# db/migrate/20260808070000 added UNIQUE (team_id, game_id) WHERE status IN
# ('new','accepted') to stop a double-clicked "apply" creating two
# simultaneously live entries. Run 1's entries stay "accepted" for ever, so
# once a game can have a second run that index permanently bars every team
# that played run 1 from applying to any later one -- enforced by the
# database, with an opaque uniqueness error and nothing a captain could act
# on.
#
# The invariant it protects is unchanged; only its scope moves.
class MoveGameEntriesUniqueIndexToRun < ActiveRecord::Migration[8.0]
  LIVE_STATUSES = %w[new accepted].freeze
  OLD_INDEX = "index_game_entries_on_team_id_and_game_id_live".freeze
  NEW_INDEX = "index_game_entries_on_team_id_and_game_run_id_live".freeze

  def up
    # Check before adding, and say rather than raise. Migrations run under
    # bin/docker-entrypoint's db:prepare BEFORE puma starts, so an index that
    # raises on unexpected data takes the whole app down mid-deploy,
    # recoverable only by someone shelling in. Production had 4 entries when
    # this was written; the guard is for restored or future data.
    duplicates = GameEntry.where(:status => LIVE_STATUSES)
                          .where.not(:game_run_id => nil)
                          .group(:team_id, :game_run_id)
                          .having("COUNT(*) > 1")
                          .count

    if duplicates.any?
      say "SKIPPED: #{duplicates.size} (team_id, game_run_id) pair(s) have more than one " \
          "live-status game_entries row -- new index NOT added and the old one LEFT IN " \
          "PLACE. Resolve the duplicates and re-run. Pairs: #{duplicates.keys.inspect}"
      return
    end

    add_index :game_entries, [ :team_id, :game_run_id ],
              unique: true,
              where: "status IN ('new', 'accepted')",
              name: NEW_INDEX

    # Only once the replacement is in place: dropping first would leave a
    # window with no protection at all if the add then failed.
    remove_index :game_entries, name: OLD_INDEX, if_exists: true
    say "moved live-entry uniqueness from (team_id, game_id) to (team_id, game_run_id)"
  end

  def down
    add_index :game_entries, [ :team_id, :game_id ],
              unique: true,
              where: "status IN ('new', 'accepted')",
              name: OLD_INDEX
    remove_index :game_entries, name: NEW_INDEX, if_exists: true
  end
end
