# -*- encoding : utf-8 -*-
class DashboardController < ApplicationController
  before_action :require_authentication!

  def index
    @invitations = Invitation.for(current_user)
    @team = current_user.team

    @games = Game.by(current_user)
    @game_entries = []
    @teams = []
    @games.each do |game|
      @game_entries.concat(GameEntry.of_game(game).with_status("new").to_a)
      @teams.concat(GameEntry.of_game(game).with_status("accepted").map(&:team))
    end
  end
end
