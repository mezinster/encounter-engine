# Unlike Admin::GamesController, which is read-only because editing rides the
# author's own forms, this console will own a write: reassigning a captain
# (added in the next commit). There is no author-facing captaincy editor to
# ride -- nothing outside TeamsController#create has ever set captain_id --
# so the operation has to live here. See
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md, S1.
class Admin::TeamsController < ApplicationController
  include SecurityFilters

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
end
