# -*- encoding : utf-8 -*-
# Issuing and revoking commercial entitlements. Operators and superadmins
# only -- see the operator-role design, D2: an operator's authority is
# scoped to gated games and nothing else.
class AccessPassesController < ApplicationController
  include AdminAudit

  before_action :require_authentication!
  before_action :find_game
  before_action :ensure_commercial_operator
  before_action :ensure_game_is_gated

  def index
    @passes = @game.access_passes.includes(:team, :attempt, :issued_by).order(:created_at)
  end

  def create
    team = Team.find_by(:name => params[:team_name].to_s.strip)

    if team.nil?
      redirect_to game_access_passes_path(@game),
                  :alert => t("access_passes.not_found") and return
    end

    pass = AccessPass.create!(:game => @game, :team => team,
                              :source => "operator_invite",
                              :issued_by => current_user)

    record_admin_action("issue_access_pass", @game, team.name)
    redirect_to game_access_passes_path(@game),
                :notice => t("access_passes.issued_notice", :team => team.name)
  end

  # Refused once the pass has an attempt, and that boundary is what keeps
  # AccessPass#spent? honest: if revocation could kill a live attempt,
  # revoked_at would start competing with the derived state for "may this
  # team play". A started run is an intervention -- see
  # InterventionsController.
  def destroy
    pass = @game.access_passes.find(params[:id])

    if pass.attempt.present?
      redirect_to game_access_passes_path(@game),
                  :alert => t("access_passes.cannot_revoke_started") and return
    end

    pass.update!(:revoked_at => Time.now)
    record_admin_action("revoke_access_pass", @game, pass.team&.name)
    redirect_to game_access_passes_path(@game),
                :notice => t("access_passes.revoked_notice")
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def ensure_commercial_operator
    raise Authentication::Unauthorized, t("errors.must_be_superadmin") unless
      current_user.may_operate_commercial?
  end

  def ensure_game_is_gated
    raise Authentication::Unauthorized, t("errors.must_be_author") unless @game.pass_required?
  end
end
