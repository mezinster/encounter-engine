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
end
