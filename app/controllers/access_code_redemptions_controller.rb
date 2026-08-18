# -*- encoding : utf-8 -*-
# A customer exchanging a purchased code for one access pass.
#
# NOT an administrative act: no AdminAction is written here. The operator
# console shows redemptions through access_codes.access_pass_id instead.
class AccessCodeRedemptionsController < ApplicationController
  include SecurityFilters
  include RequestThrottling

  before_action :require_authentication!
  before_action :send_teamless_user_to_create_one, :only => [ :create ]
  before_action :ensure_team_captain, :only => [ :create ]

  def new
    @access_code = session.delete(:pending_access_code)
  end

  def create
    unless throttle!(:access_code_redemption)
      redirect_to redeem_access_code_path, :alert => t("errors.access_code.throttled") and return
    end

    code = AccessCode.find_by_code(params[:access_code])
    return refuse(:unknown) if code.nil?
    return refuse(code.state) unless code.redeemable?
    return refuse(:game_unavailable) unless playable?(code.game)

    pass = claim(code)
    return refuse(:redeemed) if pass.nil?

    redirect_to show_current_level_path(:game_id => code.game_id),
                :notice => t("access_code_redemptions.redeemed")
  end

  private

  # A customer may buy a code before forming a team, and a 401 would be a dead
  # end. Runs BEFORE ensure_team_captain, so a user with no team at all gets
  # this redirect rather than the captain refusal -- a user who has a team but
  # does not speak for it still gets the 401, which is the point of C5.
  #
  # The code rides in the session, not the URL: it is a secret, and a query
  # string reaches logs, history and every proxy between.
  def send_teamless_user_to_create_one
    return if current_user.team

    session[:pending_access_code] = params[:access_code]
    redirect_to new_team_path, :alert => t("access_code_redemptions.need_a_team")
  end

  # The conditional claim itself lives on AccessCode#claim! (THE precondition
  # is the WHERE on that UPDATE, not a Ruby-side nil check -- see its comment).
  # This wraps it in the transaction that creates the pass and rolls back if
  # another request won the race, so a lost race never leaves an orphaned
  # AccessPass with no code pointing at it.
  #
  # :requires_new => true is required, not incidental: Rails joins a plain
  # nested `transaction do` into whatever transaction is already open rather
  # than opening a real savepoint, and `raise ActiveRecord::Rollback` inside a
  # JOINED transaction is swallowed without issuing any rollback at all. In
  # production there is no outer transaction around a request, so the plain
  # form happened to work -- but a spec running under transactional fixtures
  # (every request spec in this suite) supplies exactly that outer
  # transaction, and so would any future caller of #claim that runs inside
  # one. requires_new forces a real SAVEPOINT here, so the rollback on a lost
  # race is unconditional rather than true by luck of who calls it.
  #
  # Returns the pass, or nil when another request won the race.
  def claim(code)
    AccessCode.transaction(:requires_new => true) do
      pass = AccessPass.create!(:game => code.game, :team => current_user.team,
                                :source => "access_code")

      raise ActiveRecord::Rollback unless code.claim!(pass)

      return pass
    end

    nil
  end

  # A code cannot outlive its game's availability: withdrawn, unpublished, or
  # no longer sold by pass.
  def playable?(game)
    game.pass_required? && game.listed? && !game.withdrawn?
  end

  def refuse(reason)
    redirect_to redeem_access_code_path, :alert => t("errors.access_code.#{reason}")
  end
end
