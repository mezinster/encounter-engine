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
end
