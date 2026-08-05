# app/controllers/admin/audit_controller.rb
#
# Read-only, and there is deliberately no action that edits or deletes an
# entry. A log its own subject can edit is not a log.
class Admin::AuditController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # :actor is preloaded because the view renders one per row.
    @entries = AdminAction.includes(:actor).newest_first
  end
end
