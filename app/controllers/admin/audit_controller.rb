# app/controllers/admin/audit_controller.rb
#
# Read-only, and there is deliberately no action that edits or deletes an
# entry. A log its own subject can edit is not a log.
class Admin::AuditController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # Loaded eagerly: the id sets below have to walk the entries, and doing
    # that against a lazy relation would run the query twice.
    @entries = AdminAction.includes(:actor).newest_first.to_a

    # target_type/target_id are plain columns rather than a polymorphic
    # association, so includes cannot reach them. Two set lookups replace
    # one exists? per row -- on a log that only grows, the per-row form is
    # the page that gets slowest first.
    @live_games = live_ids(Game, "Game")
    @live_users = live_ids(User, "User")
  end

  private

  def live_ids(klass, type)
    ids = @entries.select { |e| e.target_type == type }.map(&:target_id).compact
    return Set.new if ids.empty?

    klass.where(:id => ids).pluck(:id).to_set
  end
end
