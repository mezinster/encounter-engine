# -*- encoding : utf-8 -*-
class LogsController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :find_game
  before_action :ensure_author, only: [:show_live_channel, :show_level_log, :show_game_log]
  before_action :find_team, only: [:show_level_log, :show_game_log]
  before_action :find_level, only: [:show_level_log, :show_game_log]

  # #index has no route in config/routes.rb (Task 7 only wired the four
  # show_* paths) -- same as the Merb original, whose router.rb also never
  # mapped a path to Logs#index. Kept for behavioural parity even though
  # it's unreachable both before and after this port.
  def index
  end

  # show_full_log is deliberately NOT in the :ensure_author list above --
  # that's how the Merb original had it (app/controllers/logs.rb), so any
  # logged-in user, not just the game's author, can view the full log.
  # Preserved as-is; flagged in task-8b-report.md as worth a second look.
  def show_live_channel
    @logs = Log.of_game(@game)
  end

  def show_level_log
    @logs = Log.of_game(@game).of_team(@team).of_level(@level)
  end

  def show_game_log
    @logs = Log.of_game(@game).of_team(@team)
  end

  def show_full_log
    @logs = Log.of_game(@game)
    @levels = Level.of_game(@game)
    @teams = Team.find_by_sql(
      "select * from teams t inner join game_passings gp on t.id = gp.team_id where gp.game_id = #{@game.id}"
    )
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_team
    @team = Team.find(params[:team_id])
  end

  def find_level
    @level = @team.current_level_in(@game)
  end
end
