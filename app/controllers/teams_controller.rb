# -*- encoding : utf-8 -*-
class TeamsController < ApplicationController
  before_action :require_authentication!
  before_action :ensure_not_member_of_any_team, only: [:new, :create]

  # Discovery for join requests. `resources :teams` already routed index and
  # it 404'd via ActionNotFound, so this fills an existing slot rather than
  # adding a route.
  #
  # No frozen scenario visits a teams list -- create-team.feature only visits
  # /teams/new -- so this page carries no acceptance assertions.
  def index
    # captain and members are both read per row, so both are preloaded:
    # without them this issues two extra queries per team. Pinned by the
    # slope guard in spec/requests/teams_index_spec.rb.
    @teams = Team.includes(:captain, :members).order(:name)
    # One query for the viewer's pending applications rather than one per
    # row, for the same reason.
    @pending_team_ids = TeamJoinRequest.pending.of_user(current_user).pluck(:team_id)
  end

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

  # Leaving exists so ensure_not_member_of_any_team stops being a trap: until
  # now nothing in the app set users.team_id back to nil, so a user belonged
  # to one team permanently -- and if its captain stopped logging in, every
  # member was stuck there with it.
  #
  # The team comes from current_user, never from a parameter: there is no id
  # here to forge.
  def leave
    team = current_user.team

    if team.nil?
      redirect_to dashboard_path, :alert => t("teams.not_in_a_team") and return
    end

    # D1: member-initiated changes wait for the race to end.
    if team.in_live_race?
      redirect_to team_room_path, :alert => t("teams.cannot_leave_mid_race") and return
    end

    # A captain with teammates must hand over first, or the team is left
    # bricked -- no invitations, no registration, no way to quit a race. The
    # handover control sits in the same fieldset of the team room, so this
    # refusal is a signpost rather than a dead end.
    solo = team.members.count == 1

    if current_user.captain? && !solo
      redirect_to team_room_path, :alert => t("teams.hand_over_before_leaving") and return
    end

    Team.transaction do
      # D5: a solo captain takes the role with them. Clearing captain_id is
      # not optional -- a dangling one would point team.captain at a
      # non-member while User#captain?, which reads through user.team, says
      # false. That divergence is what makes the weak
      # SecurityFilters#ensure_team_captain guard exploitable.
      #
      # This is the first thing in the app that can produce captain_id IS
      # NULL, which is what turns NotificationMailer's captainless guard from
      # precautionary into load-bearing.
            team.update!(:captain => nil) if current_user.captain?
      current_user.update!(:team => nil)
    end

    redirect_to dashboard_path, :notice => t("teams.left_notice", :team => team.name)
  end

  private

  def team_params
    params.fetch(:team, ActionController::Parameters.new).permit(:name)
  end

  def ensure_not_member_of_any_team
    raise Authentication::Unauthorized, t("game.already_in_team") if current_user.member_of_any_team?
  end
end
