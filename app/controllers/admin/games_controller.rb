# Read-only by design. Editing rides the author's own forms -- ensure_author
# admits superadmins -- so there is no second, subtly different game editor to
# keep in sync with the first.
class Admin::GamesController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # "What just appeared on my instance?" is the operator's first question.
    #
    # game_passings is preloaded because the view renders a count per row.
    # Without it this console issues one COUNT per game -- the one query
    # pattern a screen that lists *everything* can least afford.
    @games = Game.includes(:author, :game_passings).order(:created_at => :desc)
  end
end
