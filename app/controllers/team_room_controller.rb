# -*- encoding : utf-8 -*-
class TeamRoomController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :ensure_team_member

  def index
    @team = current_user.team
  end
end
