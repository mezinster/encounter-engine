# -*- encoding : utf-8 -*-
class TeamsController < ApplicationController
  before_action :require_authentication!
  before_action :ensure_not_member_of_any_team, only: [:new, :create]

  def new
    @team = Team.new
  end

  def create
    @team = Team.new(team_params)
    @team.captain = current_user

    if @team.save
      redirect_to dashboard_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def team_params
    params.fetch(:team, ActionController::Parameters.new).permit(:name)
  end

  def ensure_not_member_of_any_team
    raise Authentication::Unauthorized, t("game.already_in_team") if current_user.member_of_any_team?
  end
end
