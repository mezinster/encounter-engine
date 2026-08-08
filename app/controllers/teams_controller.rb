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

  # A captain hands the role to a teammate (D2 of the design). The superadmin
  # equivalent lives in Admin::TeamsController#set_captain; both go through
  # Team#set_captain! and nothing else writes captain_id.
  def hand_over
    team = Team.find(params[:id])

    # The STRICT guard: the team comes from the URL and the actor must be
    # THIS team's captain. Deliberately not SecurityFilters
    # #ensure_team_captain, which only asks "is this user a captain" and
    # derives the team from current_user -- it would admit the captain of any
    # other team to this action. Same reasoning as
    # GameEntriesController#ensure_captain_of_target_team, which exists
    # because that controller also takes its team from the URL.
    raise Authentication::Unauthorized, t("errors.must_be_captain") unless
      team.captain && team.captain.id == current_user.id

    # D1: member-initiated changes wait for the race to end. The superadmin
    # path is deliberately unguarded here -- see the comment on
    # Team#in_live_race?.
    if team.in_live_race?
      redirect_to team_room_path, :alert => t("teams.cannot_hand_over_mid_race") and return
    end

    # Scoped through team.members, so a crafted id from another team resolves
    # to nil and is refused rather than reaching set_captain! and raising.
    successor = team.members.find_by(:id => params[:member_id])

    if successor.nil? || successor.id == current_user.id
      redirect_to team_room_path, :alert => t("teams.hand_over_needs_another_member") and return
    end

    team.set_captain!(successor)
    redirect_to team_room_path,
                :notice => t("teams.handed_over", :nickname => successor.nickname)
  end

  private

  def team_params
    params.fetch(:team, ActionController::Parameters.new).permit(:name)
  end

  def ensure_not_member_of_any_team
    raise Authentication::Unauthorized, t("game.already_in_team") if current_user.member_of_any_team?
  end
end
