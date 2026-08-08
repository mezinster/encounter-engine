# -*- encoding : utf-8 -*-
class LogsController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :find_game
  before_action :ensure_author, only: [:show_live_channel, :show_level_log, :show_game_log]
  before_action :ensure_full_log_access, only: [:show_full_log]
  before_action :find_team, only: [:show_level_log, :show_game_log]
  before_action :find_level, only: [:show_level_log, :show_game_log]

  # #index has no route in config/routes.rb (Task 7 only wired the four
  # show_* paths) -- same as the Merb original, whose router.rb also never
  # mapped a path to Logs#index. Kept for behavioural parity even though
  # it's unreachable both before and after this port.
  def index
  end

  # SECURITY FIX (see .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-S-report.md):
  # show_full_log used to be reachable by ANY logged-in user -- it was
  # deliberately left out of the :ensure_author list above, matching the
  # Merb original (app/controllers/logs.rb), which had no author check on
  # this action at all. Since the view prints every level's correct_answer
  # for the whole game, that let a team still playing a live game read every
  # remaining answer code. The full log has two legitimate audiences --
  # the game's author (features/logs/log.feature:105) and a player whose
  # team has *finished* the game (features/logs/log.feature:113) -- so
  # #show_full_log now goes through :ensure_full_log_access instead of
  # :ensure_author, which allows exactly those two cases and blocks a team
  # that is still mid-game.
  def show_live_channel
    @logs = Log.of_game(@game).includes(:team_record, :level_record)
  end

  def show_level_log
    # find_level (before_action) resolves @level via Team#current_level_in,
    # which returns nil once GamePassing#pass_level! finishes a team's game
    # (current_level is niled on the final level -- see GamePassing#pass_level!).
    # Reachable only by a finished team hitting this URL directly; no UI link
    # does it. Guard explicitly rather than calling of_level(nil): the id-scoped
    # fallback above still resolves `level.id`/`level.name` on its argument, so
    # a nil @level would raise the same NoMethodError the old name-only scope
    # did -- but relying on that as the safety net is an accident waiting to
    # break the next time this scope changes shape. Render an empty log instead.
    if @level.nil?
      @logs = Log.none
      render plain: "", :status => :ok
      return
    end

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

  # Allowed: the game's author, or a player on a team that genuinely
  # finished the game -- GamePassing#finished? alone is not enough, because
  # it is also true for a team that merely *exited* (GamePassing#exit! sets
  # finished_at too). An exited team cannot resume play (ensure_team_not_exited
  # in GamePassingsController blocks both GET and POST /play/:id), but
  # without the exited? check here, one team could exit on purpose mid-game
  # purely to unlock the full log and relay every remaining answer code to
  # a colluding team that is still playing -- the cost of that attack is one
  # throwaway team, not actually finishing the game. Both real full-log
  # scenarios (features/logs/log.feature:113,
  # features/games/game_full_log.feature:20) reach this page by completing
  # every level through real gameplay, never by exiting, so requiring
  # !exited? breaks neither. Blocked: a team still mid-game, an exited team,
  # and anyone with no team at all.
  def ensure_full_log_access
    return if @game.created_by?(current_user)

    game_passing = current_user.team && GamePassing.of(current_user.team, @game)
    unless game_passing&.finished? && !game_passing.exited?
      raise Authentication::Unauthorized, t("errors.must_be_author_or_finished_player")
    end
  end
end
