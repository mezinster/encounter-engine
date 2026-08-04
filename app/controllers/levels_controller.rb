# -*- encoding : utf-8 -*-
class LevelsController < ApplicationController
  include SecurityFilters

  # No require_authentication! here: the Merb original never had a separate
  # ensure_authenticated filter for this controller, only ensure_author
  # (below), which rejects a guest and a logged-in non-author with the same
  # Unauthorized response. Splitting that into a distinct "must log in"
  # redirect would be a behaviour change this task doesn't ask for.
  before_action :find_game
  before_action :ensure_author
  before_action :ensure_game_was_not_started, only: [:new, :create, :edit, :update, :delete]
  before_action :find_level, except: [:new, :create]

  def new
    @level = @game.levels.build
  end

  def create
    @level = @game.levels.build(level_params)

    if @level.save
      redirect_to [@game, @level]
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def edit
  end

  def update
    if @level.update(level_params)
      redirect_to [@level.game, @level]
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def delete
    @level.destroy
    redirect_to @game
  end

  def move_up
    @level.move_higher
    redirect_to @game
  end

  def move_down
    @level.move_lower
    redirect_to @game
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_level
    @level = Level.find(params[:id])
  end

  # correct_answer is Level's virtual setter (see app/models/level.rb) that
  # builds the level's first Question/Answer pair -- only submitted by the
  # "new level" form, not by "edit", but it's harmless to permit on both.
  def level_params
    params.fetch(:level, ActionController::Parameters.new)
          .permit(:name, :text, :correct_answer)
  end
end
