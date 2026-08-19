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
  before_action :find_game_passing,
                only: [ :move, :reinstate, :reset_clock, :skip_level,
                        :new_adjustment, :create_adjustment ]

  # A7: an adjustment is usually a judgement made AFTER a run -- a dispute
  # settled the next morning, a location confirmed broken once the game is
  # over. The commonest adjustment is one nobody could have made while the run
  # was live, so these two actions are the only ones here that must survive a
  # game that has ended.
  skip_before_action :ensure_game_is_live, only: [ :new_adjustment, :create_adjustment ]

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

  # Shares skip_level! with the captain's own button, so it is bound by the
  # same cap and raises the same ArgumentError -- which rescue_from turns into
  # a refusal, exactly as it does for every other action here. current_user is
  # passed as the actor, so the ledger row records who spent the team's points.
  def skip_level
    @game_passing.skip_level!(current_user)
    audit("skip_level", @game_passing.team.name)
    back_to_stats(t("interventions.skipped_notice"))
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

  def new_adjustment
    @amount = nil
    @note   = nil
  end

  def create_adjustment
    @amount = params[:amount].to_i
    @note   = params[:note].to_s

    return render(:confirm_adjustment) if params[:confirmed].blank?

    PointTransaction.adjust!(:team => @game_passing.team, :amount => @amount,
                             :note => @note, :actor => current_user,
                             :passing => @game_passing)
    audit("adjust_points", @game_passing.team.name)
    back_to_stats(t("interventions.adjusted_notice"))
  rescue ActiveRecord::RecordInvalid
    render :new_adjustment, :status => :unprocessable_entity
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
