# One passing per team per run. Until now the invariant was enforced only by
# GamePassingsController#find_or_create_game_passing's read, so two
# near-simultaneous first requests could each miss and create one.
class AddUniqueIndexToGamePassingsOnTeamAndRun < ActiveRecord::Migration[8.0]
  def up
    # Check first rather than letting add_index raise. Migrations run under
    # bin/docker-entrypoint's db:prepare BEFORE puma starts, so an index that
    # raises on unexpected data takes the whole app down mid-deploy with an
    # opaque uniqueness error, recoverable only by someone shelling in to clean
    # the table by hand. Saying so and completing keeps the app up; the index
    # is simply absent until someone resolves the duplicates and re-runs this.
    #
    # Production had 3 game_passings when this was written, so it will not
    # fire there -- the guard is for restored or future data.
    duplicates = GamePassing.where.not(:game_run_id => nil)
                            .group(:team_id, :game_run_id)
                            .having("COUNT(*) > 1")
                            .count

    if duplicates.any?
      say "SKIPPED: #{duplicates.size} (team_id, game_run_id) pair(s) have more than one " \
          "game_passings row -- unique index NOT added. Resolve the duplicates and re-run " \
          "this migration. Pairs: #{duplicates.keys.inspect}"
    else
      add_index :game_passings, [ :team_id, :game_run_id ],
                unique: true,
                name: "index_game_passings_on_team_id_and_game_run_id"
      say "added unique index on game_passings (team_id, game_run_id)"
    end
  end

  def down
    remove_index :game_passings,
                 name: "index_game_passings_on_team_id_and_game_run_id",
                 if_exists: true
  end
end
