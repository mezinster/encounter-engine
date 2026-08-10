# -*- encoding : utf-8 -*-
class DashboardController < ApplicationController
  before_action :require_authentication!

  def index
    @invitations = Invitation.for(current_user)
    @team = current_user.team

    @games = Game.by(current_user)
    @game_entries = []
    @games.each do |game|
      @game_entries.concat(GameEntry.of_run(game.current_run).with_status("new").to_a)
    end

    @teams_by_game = accepted_teams_by_game(@games)
  end

  private

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
