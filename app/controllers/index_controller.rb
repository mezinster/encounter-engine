# -*- encoding : utf-8 -*-
class IndexController < ApplicationController
  # Same scope as GamesController#index's no-user_id branch: a withdrawn or
  # draft game must stay off the home page exactly as it stays off /games.
  def index
    @games = Game.visible
  end
end
