# -*- encoding : utf-8 -*-
#
# Applying to join a team -- the user -> captain direction. Deciding lives in
# TeamJoinDecisionsController, because the two halves have different actors
# and therefore different guards: anyone may apply, only the target team's
# captain may decide.
#
# See docs/superpowers/specs/2026-08-08-team-membership-programme-design.md,
# S4.
class TeamJoinRequestsController < ApplicationController
  before_action :require_authentication!

  def create
    team = Team.find_by(:id => params[:team_id])

    if team.nil?
      redirect_to teams_path, :alert => t("team_join_requests.unknown_team") and return
    end

    # A captain cannot transfer: accepting would detach them and leave their
    # own team captainless WITH members, which is the bricked state this
    # programme exists to remove. Hand over (team room) or leave first --
    # the message names it, so the refusal is a signpost.
    if current_user.captain?
      redirect_to teams_path,
                  :alert => t("team_join_requests.captain_must_hand_over_first") and return
    end

    if current_user.team == team
      redirect_to teams_path, :alert => t("team_join_requests.already_a_member") and return
    end

    # D1: member-initiated changes wait for the race to end. Only the
    # applicant's own team matters here -- the target team's race is checked
    # when its captain accepts, since it may well have ended by then.
    if current_user.team&.in_live_race?
      redirect_to teams_path, :alert => t("team_join_requests.cannot_apply_mid_race") and return
    end

    # Refused before insert rather than rescuing RecordNotUnique from the
    # partial index: a double-clicked button should be a message, not a 500.
    # The index stays as the backstop against two simultaneous requests.
    if TeamJoinRequest.pending.of_user(current_user).to_team(team).exists?
      redirect_to teams_path, :alert => t("team_join_requests.already_applied") and return
    end

    TeamJoinRequest.create!(:user => current_user, :team => team)
    redirect_to teams_path, :notice => t("team_join_requests.sent", :team => team.name)
  end
end
