# app/controllers/interventions_controller.rb
#
# Operator actions on a game that is actually being played. Every action calls
# a named model method and redirects back to the stats page -- nothing here
# writes a column directly, which is what keeps a tired operator from producing
# a passing the model has no path to.
class InterventionsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :find_game
  # ensure_author already means "the author, or any superadmin", and
  # ensure_editing_not_locked already exempts superadmins -- together they give
  # this feature's whole authorization rule with no new concept.
  before_action :ensure_author
  before_action :ensure_editing_not_locked
  before_action :ensure_game_is_live
  before_action :find_game_passing, only: [ :move, :reinstate, :reset_clock ]

  # The model methods raise ArgumentError when they refuse. One rescue covers
  # every refusal, so no action has to duplicate the check its model already does.
  rescue_from ArgumentError, with: :refused

  def pause
    @game.pause!
    audit("pause")
    back_to_stats(t("interventions.paused_notice"))
  end

  def resume
    @game.resume!
    audit("resume")
    back_to_stats(t("interventions.resumed_notice"))
  end

  def move
    level = Level.find(params[:level_id])
    @game_passing.move_to_level!(level)
    audit("move_team", @game_passing.team.name)
    back_to_stats(t("interventions.moved_notice"))
  end

  def reinstate
    @game_passing.reinstate!
    audit("reinstate_team", @game_passing.team.name)
    back_to_stats(t("interventions.reinstated_notice"))
  end

  def reset_clock
    @game_passing.reset_level_clock!
    audit("reset_clock", @game_passing.team.name)
    back_to_stats(t("interventions.clock_reset_notice"))
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_game_passing
    @game_passing = GamePassing.of_game(@game).of_team(params[:team_id]).first
    raise ActiveRecord::RecordNotFound unless @game_passing
  end

  # Recorded after the change lands, and only for an operator acting on someone
  # else's game -- sub-project B's rule. The target is the game; `details`
  # carries the team, which a single-target row could not otherwise hold.
  def audit(action, details = nil)
    record_admin_action(action, @game, details) if acting_as_operator?(@game)
  end

  def back_to_stats(notice)
    redirect_to game_stats_path(:index, @game), :notice => notice
  end

  def refused(exception)
    redirect_to game_stats_path(:index, @game), :alert => t("interventions.refused")
  end
end
