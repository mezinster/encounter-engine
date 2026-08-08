# -*- encoding : utf-8 -*-
#
# The deciding half of S4: only the TARGET team's captain may accept or
# reject a request addressed to that team. Separate from
# TeamJoinRequestsController because the actor is different -- anyone may
# apply, only one specific person may decide -- and so the guard is too.
#
# See docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
class TeamJoinDecisionsController < ApplicationController
  before_action :require_authentication!
  before_action :find_request
  before_action :ensure_captain_of_target_team

  def accept
    unless @request.pending?
      redirect_to team_room_path, :alert => t("team_join_requests.already_decided") and return
    end

    applicant = @request.user
    source = applicant.team

    # The applicant may have created a team since applying. Accepting would
    # detach them and leave it captainless WITH members -- the bricked state.
    # Checked again here rather than trusting the check made when they
    # applied, because time has passed.
    if applicant.captain?
      redirect_to team_room_path,
                  :alert => t("team_join_requests.applicant_is_a_captain") and return
    end

    # D1, both ends. The applicant's team was checked when they applied, but
    # a race may have started since; the target team's is checked here for
    # the first time, deliberately -- refusing an APPLICATION because the
    # target happened to be racing would be needlessly strict, since the
    # request just waits.
    if @request.team.in_live_race? || source&.in_live_race?
      redirect_to team_room_path,
                  :alert => t("team_join_requests.cannot_decide_mid_race") and return
    end

    TeamJoinRequest.transaction do
      applicant.update!(:team => @request.team)
      @request.accept!
      TeamJoinRequest.pending.of_user(applicant).where.not(:id => @request.id)
                     .find_each(&:reject!)
      # Mirrors InvitationsController#reject_rest_of_invitations: an applicant
      # who has landed somewhere must not be left holding live applications
      # elsewhere, which another captain would later accept into nothing.
    end

    redirect_to team_room_path,
                :notice => t("team_join_requests.accepted", :nickname => applicant.nickname)
  end

  def reject
    unless @request.pending?
      redirect_to team_room_path, :alert => t("team_join_requests.already_decided") and return
    end

    @request.reject!
    redirect_to team_room_path,
                :notice => t("team_join_requests.rejected", :nickname => @request.user.nickname)
  end

  private

  def find_request
    @request = TeamJoinRequest.find(params[:id])
  end

  # The STRICT guard: the team comes from the REQUEST, and the actor must be
  # that team's captain. Deliberately not SecurityFilters#ensure_team_captain,
  # which only asks "is this user a captain" and derives the team from
  # current_user -- it would let the captain of team A decide team B's
  # requests. Phase 2's mutation proved that hole is real, not theoretical.
  # Same shape as GameEntriesController#ensure_captain_of_target_team.
  def ensure_captain_of_target_team
    team = @request.team

    raise Authentication::Unauthorized, t("errors.must_be_captain") unless
      team && team.captain && team.captain.id == current_user.id
  end
end
