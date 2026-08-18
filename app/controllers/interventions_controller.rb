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
  # ensure_author already means "the author, any superadmin, or an operator on
  # a gated game", and ensure_editing_not_locked already exempts superadmins
  # -- together they give this feature's whole authorization rule with no new
  # concept.
  before_action :ensure_author
  before_action :ensure_editing_not_locked
  before_action :ensure_game_is_live
  before_action :find_game_passing, only: [ :move, :reinstate, :reset_clock ]

  # Deliberately narrower than ensure_author, which every other action here
  # uses and which also admits an operator on a gated game. Changing how codes
  # count alters the difficulty of a race already in progress, for every team
  # at once, after some have committed effort to the harder rule. An operator
  # doing that leaves an audited entry and is answerable for it; an author
  # doing it to their own live game is the same act with none of that.
  before_action :require_superadmin!, only: [ :allow_any_code, :require_all_codes ]
  before_action :find_level,          only: [ :allow_any_code, :require_all_codes ]

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

  def allow_any_code
    @level.allow_any_code!
    audit_level("allow_any_code")
    back_to_stats(t("interventions.any_code_notice", :name => @level.name))
  end

  def require_all_codes
    @level.require_all_codes!
    audit_level("require_all_codes")
    back_to_stats(t("interventions.all_codes_notice", :name => @level.name))
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  # A commercial attempt carries game_run_id: nil (GamePassingsController
  # never places it in a run), so @game.current_run.passings -- scoped by
  # game_run_id -- can never see it. Without this branch, move_to_level!,
  # reinstate! and reset_level_clock! are all unreachable for a gated game's
  # attempt, and AccessPassesController#destroy's "a started run is an
  # intervention" refusal points at a tool that cannot touch the attempt it
  # just refused to release. The scheduled branch is unchanged.
  #
  # GamePassing.gated_attempt_for is THE single definition of "this team's
  # current attempt" for the gated branch -- finding 3 of the whole-branch
  # review. This used to run with no order at all, which under SQLite
  # returned the OLDEST, already-completed attempt for a team holding two --
  # exactly wrong for reinstate, whose whole purpose is rescuing the team's
  # most recent one.
  def find_game_passing
    @game_passing = @game.pass_required? ?
                       GamePassing.gated_attempt_for(@game, params[:team_id]) :
                       @game.current_run.passings.of_team(params[:team_id]).first
    raise ActiveRecord::RecordNotFound unless @game_passing
  end

  # Scoped through the game, so a level id belonging to another game 404s.
  def find_level
    @level = @game.levels.find(params[:id])
  end

  # Recorded after the change lands, and only for an operator acting on someone
  # else's game -- sub-project B's rule. The target is the game; `details`
  # carries the team, which a single-target row could not otherwise hold.
  def audit(action, details = nil)
    record_admin_action(action, @game, details) if acting_as_operator?(@game)
  end

  # record_admin_action directly, NOT through audit() above. That helper is
  # gated by acting_as_operator?, which is false when the superadmin owns the
  # game -- correct for pause and move, which an author may also perform, but
  # wrong here. These two actions are reachable only by a superadmin, so going
  # through audit() would record nothing in precisely the case an audit trail
  # exists for: actor and beneficiary being the same person.
  #
  # The target is the LEVEL, not the game, so the entry names which level
  # changed.
  def audit_level(action)
    record_admin_action(action, @level)
  end

  def back_to_stats(notice)
    redirect_to game_stats_path(@game), :notice => notice
  end

  def refused(exception)
    redirect_to game_stats_path(@game), :alert => t("interventions.refused")
  end
end
