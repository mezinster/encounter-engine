# Unlike Admin::GamesController, which is read-only because editing rides the
# author's own forms, this console will own a write: reassigning a captain
# (added in the next commit). There is no author-facing captaincy editor to
# ride -- nothing outside TeamsController#create has ever set captain_id --
# so the operation has to live here. See
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md, S1.
class Admin::TeamsController < ApplicationController
  include SecurityFilters
  # Not inherited from ApplicationController -- each audited controller
  # includes it explicitly, as Admin::UsersController does.
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # captain and members are both rendered per row, so both are preloaded.
    # Without them this screen issues two extra queries per team -- the
    # pattern Admin::GamesController's comment calls out as the one a listing
    # of everything can least afford. Pinned by the slope guard in
    # spec/requests/admin_teams_spec.rb.
    @teams = Team.includes(:captain, :members).order(:name)
  end

  # Deliberately NOT guarded on Team#in_live_race?, unlike the captain's own
  # handover in TeamsController#hand_over. The abandoned-captain case is most
  # acute mid-race -- quitting the race is itself captain-only, so a team
  # whose captain has vanished cannot even withdraw -- and refusing rescue
  # exactly when it is needed would be the wrong trade. D1 of the design;
  # both sides of the asymmetry are pinned by specs so it is not "fixed" into
  # consistency later.
  # Reclaims the inert tombstone D5 leaves behind when a solo captain leaves,
  # and with it the team name, which Team validates unique and which would
  # otherwise stay reserved forever.
  #
  # Team#deletable? is deliberately narrow -- see its comment. Everything the
  # predicate refuses is refused here too, before anything changes, so no
  # audit entry is written for a deletion that did not happen.
  def destroy
    team = Team.find(params[:id])

    unless team.deletable?
      redirect_to admin_teams_path, :alert => t("admin.teams.not_deletable") and return
    end

    team.destroy

    # Recorded with the destroyed record: it is frozen but still readable, so
    # target_label snapshots the name while target_id keeps the id that now
    # points at nothing.
    record_admin_action("delete_team", team)
    redirect_to admin_teams_path,
                :notice => t("admin.teams.deleted_notice", :name => team.name)
  end

  def set_captain
    team = Team.find(params[:id])
    # Looked up THROUGH team.members rather than User.find: a crafted
    # member_id belonging to another team resolves to nil and is refused
    # here, so it never reaches set_captain! and never risks the theft path
    # at all. Same scoping discipline as
    # GameEntriesController#ensure_captain_of_target_team.
    member = team.members.find_by(:id => params[:member_id])

    if member.nil?
      redirect_to admin_teams_path, :alert => t("admin.teams.not_a_member") and return
    end

    team.set_captain!(member)
    record_admin_action("set_captain", team, member.nickname)
    redirect_to admin_teams_path,
                :notice => t("admin.teams.captain_set", :nickname => member.nickname)
  end
end
