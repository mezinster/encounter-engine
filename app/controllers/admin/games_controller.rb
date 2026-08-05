# Read-only by design. Editing rides the author's own forms -- ensure_author
# admits superadmins -- so there is no second, subtly different game editor to
# keep in sync with the first.
class Admin::GamesController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # "What just appeared on my instance?" is the operator's first question.
    @games = Game.includes(:author).order(:created_at => :desc)
  end
end
