# Read-only. Every figure is a SQL aggregate rather than a count over a loaded
# collection -- an admin page that loads every row in order to count it becomes
# the slowest page on the site precisely when the instance gets interesting.
class Admin::DashboardController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    @games_by_status   = Game.count_by_status
    @editing_locked    = Game.editing_locked_count
    @entries_by_status = GameEntry.group(:status).count

    @counts = {
      :users => User.count,
      :teams => Team.count,
      :games => Game.count,
      :passings_finished => GamePassing.finished.count,
      :passings_in_progress => GamePassing.where(:finished_at => nil).count
    }
  end
end
