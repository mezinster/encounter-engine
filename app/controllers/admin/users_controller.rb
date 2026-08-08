# Read-only, and deliberately split: the list carries identity and email, the
# detail page carries contact details. Nothing is hidden from the operator, but
# reading the whole membership's phone numbers takes deliberate clicks rather
# than one glance -- which is what matters once this role can be granted to a
# helper.
#
# crypted_password and salt are never passed to a view. A spec asserts their
# absence across every reporting screen: the risk is not that someone adds them
# deliberately but that a future `<%= user.attributes %>` leaks them silently.
class Admin::UsersController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # :team is preloaded because the list renders one per row. Without it this
    # page issues a SELECT per user -- the exact defect the all-games console
    # shipped with, found only when a reviewer instrumented it.
    @users = User.includes(:team).order(:created_at => :desc)
  end

  def show
    @user = User.includes(:team, :created_games).find(params[:id])
  end

  def grant
    user = User.find(params[:id])
    user.update!(:is_superadmin => true)
    record_admin_action("grant_superadmin", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.granted_notice")
  end

  def revoke
    user = User.find(params[:id])

    # Refused before anything changes, so neither guard leaves an entry for a
    # revocation that did not happen.
    if user.id == current_user.id
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_revoke_self") and return
    end

    if user.last_superadmin?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_revoke_last") and return
    end

    user.update!(:is_superadmin => false)
    record_admin_action("revoke_superadmin", user)
    redirect_to admin_user_path(user), :notice => t("admin.users.revoked_notice")
  end

  # Consent-free, so the refusals matter more than the move. See
  # docs/superpowers/specs/2026-08-08-team-membership-programme-design.md, S2.
  # Every guard refuses before anything changes, matching #revoke above, so no
  # audit entry is ever written for a move that did not happen.
  def move
    user = User.find(params[:id])
    destination = Team.find_by(:id => params[:team_id])
    source = user.team

    # Moving a captain would leave their team captainless -- the bricked state
    # this programme exists to remove -- and would put users.team_id and
    # teams.captain_id in disagreement, which is the divergence that makes the
    # weak SecurityFilters#ensure_team_captain guard exploitable. The message
    # names the remedy, or an operator meets a refusal with no hint at the fix.
    if user.captain?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_move_captain") and return
    end

    if destination.nil? || destination == source
      redirect_to admin_user_path(user), :alert => t("admin.users.move_needs_another_team") and return
    end

    # D1: consent-free changes wait for the race to end. Both ends matter --
    # joining a run already under way hands the newcomer levels their
    # teammates solved, and leaving one changes a racing team's composition
    # without its captain knowing.
    if destination.in_live_race? || source&.in_live_race?
      redirect_to admin_user_path(user), :alert => t("admin.users.cannot_move_mid_race") and return
    end

    user.update!(:team => destination)
    record_admin_action("move_user", user, "#{source&.name} -> #{destination.name}")
    redirect_to admin_user_path(user),
                :notice => t("admin.users.moved_notice", :team => destination.name)
  end
end
