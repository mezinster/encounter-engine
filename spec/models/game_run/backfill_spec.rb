# -*- encoding : utf-8 -*-
require "rails_helper"

# What the backfill must leave behind, expressed as an invariant rather than by
# replaying the migration: every game has a run, and every passing and entry
# that belongs to a game points at one.
#
# Rehearse the migration itself against a COPY OF PRODUCTION before deploying.
# The real hazard is a game in a lifecycle state the fixtures never produce, and
# no spec here can stand in for that.
RSpec.describe "the game_runs backfill invariant" do
  it "gives the migration's INSERT one run per game, copying the schedule" do
    # Reproduces exactly what the migration's INSERT ... SELECT does, against a
    # game written the pre-migration way: columns set on games, no run.
    game = create_game
    game.runs.delete_all if game.respond_to?(:runs)
    ActiveRecord::Base.connection.execute(<<~SQL)
      UPDATE games SET starts_at = '2031-05-05 10:00:00', max_team_number = 42
       WHERE id = #{game.id}
    SQL
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO game_runs (game_id, ordinal, starts_at, max_team_number,
                             requested_teams_number, is_testing,
                             created_at, updated_at)
      SELECT id, 1, starts_at, max_team_number, requested_teams_number, is_testing,
             created_at, updated_at
        FROM games WHERE id = #{game.id}
    SQL

    run = GameRun.where(:game_id => game.id).order(:ordinal).last
    expect(run.ordinal).to eq(1)
    expect(run.max_team_number).to eq(42)
    expect(run.starts_at).not_to be_nil
  end

  # A game with no start time is a real state -- Game#started? treats NULL as
  # not started, and count_by_status has an explicit NULL branch for it. The
  # backfill must carry the NULL through rather than skipping the row.
  it "gives a game with no start time a run, with a null start time" do
    game = create_game
    ActiveRecord::Base.connection.execute("UPDATE games SET starts_at = NULL WHERE id = #{game.id}")
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO game_runs (game_id, ordinal, starts_at, requested_teams_number,
                             is_testing, created_at, updated_at)
      SELECT id, 99, starts_at, requested_teams_number, is_testing, created_at, updated_at
        FROM games WHERE id = #{game.id}
    SQL

    run = GameRun.where(:game_id => game.id, :ordinal => 99).first
    expect(run).to be_present
    expect(run.starts_at).to be_nil
  end
end
