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
      # Three outcomes that add up, rather than two that overlap and leave a
      # gap. See the scopes in GamePassing: `finished_at IS NULL` alone
      # reported every team the author had ended as still playing, and
      # `GamePassing.finished` files a team that walked off the course under
      # the same heading as one that crossed the line.
      :passings_finished => GamePassing.completed.count,
      :passings_interrupted => GamePassing.interrupted.count,
      :passings_in_progress => GamePassing.in_progress.count
    }

    @storage_used_megabytes = GameFile.storage_used_everywhere / 1024 / 1024
    @storage_cap_megabytes = Setting.integer("instance_cap_megabytes")
    # GameFileUpload.storage_root, NOT Rails.root: the figure below it on this
    # page is free_space_floor_megabytes, the threshold the upload guard
    # compares against, and the guard measures the Active Storage service root.
    # Rails.root here put two numbers side by side, labelled as if they were
    # comparable, taken from two different filesystems. They resolve to the
    # same device today, so the bug was invisible -- and stops being invisible
    # the day /rails/storage becomes the separate partition config/storage.yml
    # recommends, at which point this panel reads healthy while every upload is
    # being refused.
    @disk_free_megabytes = DiskSpace.available_megabytes(GameFileUpload.storage_root)
    @disk_floor_megabytes = Setting.integer("free_space_floor_megabytes")
  end
end
