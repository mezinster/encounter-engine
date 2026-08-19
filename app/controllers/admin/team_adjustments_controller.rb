# -*- encoding : utf-8 -*-
# A global adjustment: one that belongs to the team rather than to any run.
#
# Superadmin-only, unlike its game-scoped counterpart on
# InterventionsController. That controller's ensure_author means "the author,
# any superadmin, or an operator on a gated game" -- all defined RELATIVE TO A
# GAME. A global row has no game, so there is no author for it to admit, and
# it reaches every game the team has ever played. The narrower authority
# matches the wider blast radius.
class Admin::TeamAdjustmentsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!
  before_action :find_team

  def new
    @amount = nil
    @note   = nil
  end

  def create
    @amount = params[:amount].to_i
    @note   = params[:note].to_s

    return render(:confirm) if params[:confirmed].blank?

    PointTransaction.adjust!(:team => @team, :amount => @amount,
                             :note => @note, :actor => current_user)
    # `details` carries the amount and the note. Without them the entry said a
    # team had been adjusted globally and neither by how much nor why -- on the
    # door with the wider blast radius of the two, since a global row reaches
    # every game the team has ever played. Spec section 4.4; F3 of the
    # whole-branch review.
    record_admin_action("adjust_points_globally", @team,
                        adjustment_details(@team, @amount, @note))
    redirect_to admin_teams_path, :notice => t("admin.team_adjustments.done")
  rescue ActiveRecord::RecordInvalid
    render :new, :status => :unprocessable_entity
  end

  private

  def find_team
    @team = Team.find(params[:team_id])
  end
end
