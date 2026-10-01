# -*- encoding : utf-8 -*-
class IndexController < ApplicationController
  def index
    # The home page's games, classified and capped (app/services/upcoming_games.rb).
    # The full list lives at /games behind the "Список игр" link.
    @upcoming = UpcomingGames.call
  end
end
