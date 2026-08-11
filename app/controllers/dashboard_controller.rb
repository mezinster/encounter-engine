# -*- encoding : utf-8 -*-
class DashboardController < ApplicationController
  before_action :require_authentication!

  def index
    @invitations = Invitation.for(current_user)
    @team = current_user.team

    # includes(:runs) because everything below reads game.current_run, which is
    # `runs.to_a.last` -- without the preload that is one query per game, on
    # the page an author opens most often.
    @games = Game.by(current_user).includes(:runs)
    @game_entries = pending_entries_for(@games)
    @teams_by_game = accepted_teams_by_game(@games)
  end

  private

  # Was a loop issuing GameEntry.of_run(game.current_run) once per game, beside
  # a @games with no preload -- so the dashboard asked about each game
  # separately, twice. Measured at 20 queries for one game and 65 for ten.
  # spec/requests/dashboard_queries_spec.rb pins the slope.
  #
  # Run-scoped exactly as the loop was, and for the same reason
  # #accepted_teams_by_game gives below: an author whose game is on its second
  # run must be shown that run's applicants, not every cohort that ever
  # applied.
  #
  # Ordered explicitly. The loop produced entries grouped by game in @games'
  # order; without an ORDER BY the batched query would return whatever the
  # database felt like, and the partial renders one flat list where a stable
  # order is the difference between a list and a shuffle.
  def pending_entries_for(games)
    run_ids = games.map { |game| game.current_run.id }.compact

    GameEntry.with_status("new")
             .where(:game_run_id => run_ids)
             .includes(:team, :game)
             .order(:game_id, :id)
  end

  # One query for every accepted entry across the author's games (team
  # preloaded), instead of the old per-game query-then-map(&:team). Skips
  # games with no accepted teams and keeps @games' own order, so an author
  # with several games doesn't get a wall of empty groups.
  # Grouped by RUN, not by game. An author with a game on its second run must
  # see who is registered for THAT run, not everyone who ever played it --
  # scoping on game_id would pile every past cohort into the card.
  #
  # Still one query for every accepted entry across the author's games (team
  # preloaded), instead of the old per-game query-then-map(&:team). Skips
  # games with no accepted teams and keeps @games' own order, so an author
  # with several games doesn't get a wall of empty groups.
  def accepted_teams_by_game(games)
    runs_by_game = games.each_with_object({}) { |game, by_game| by_game[game] = game.current_run }

    entries = GameEntry.with_status("accepted")
                       .where(:game_run_id => runs_by_game.values.map(&:id))
                       .includes(:team)
    teams_by_run_id = entries.group_by(&:game_run_id)

    games.each_with_object({}) do |game, grouped|
      teams = teams_by_run_id[runs_by_game[game].id]
      grouped[game] = teams.map(&:team) if teams.present?
    end
  end
end
