# -*- encoding : utf-8 -*-
class TeamRoomController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :ensure_team_member

  def index
    @team = current_user.team
    # Only the captain can decide, so only the captain is shown the queue.
    # :user is preloaded because the view names each applicant.
    @join_requests = if current_user.captain?
                       TeamJoinRequest.pending.to_team(@team).includes(:user).order(:created_at)
                     else
                       []
                     end
  end
end
