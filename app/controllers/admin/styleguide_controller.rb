# A page that renders every shared component, for reviewing the theme on a
# real device and for spec/layout/styleguide_layout_spec.rb to measure.
#
# Read-only, so no AdminAudit call: that concern records changes, and
# spec/requests/admin_audit_spec.rb enumerates only mutating actions.
class Admin::StyleguideController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    # The invalid specimens are drawn by the real field_error_proc. valid?
    # writes nothing; the uniqueness check on name only reads.
    @invalid_game = Game.new(:name => "", :max_team_number => 0, :visibility => "bogus")
    @invalid_game.valid?
    @valid_game = Game.new(:name => "Ночной город", :max_team_number => 12, :visibility => "listed")
  end
end
