# -*- encoding : utf-8 -*-
class HintsController < ApplicationController
  include SecurityFilters

  # No #index action: the Merb original (app/controllers/hints.rb) never had
  # one either -- the hint list is rendered as a partial from the level's
  # show page (app/views/hints/_list.html.erb), not a dedicated action.
  # config/routes.rb's `resources :hints` still declares the index route (it
  # did in Merb's router too, via `levels.resources :hints`), so the route
  # exists but is unreachable, same as before this port.
  before_action :find_level
  before_action :find_game
  before_action :build_hint, only: [:new, :create]
  before_action :find_hint, only: [:edit, :update, :delete]
  before_action :ensure_author
  before_action :ensure_game_was_not_started, only: [:new, :create, :edit, :update]

  def new
  end

  def create
    if @hint.save
      redirect_to [@game, @level]
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @hint.update(hint_params)
      redirect_to [@level.game, @level]
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def delete
    @hint.destroy
    redirect_to [@level.game, @level]
  end

  private

  def build_hint
    @hint = Hint.new(hint_params)
    @hint.level = @level
  end

  def find_level
    @level = Level.find(params[:level_id])
  end

  def find_game
    @game = @level.game
  end

  def find_hint
    @hint = Hint.find(params[:id])
  end

  # app/views/hints/_form.html.erb submits :text and :delay_in_minutes (a
  # virtual setter on Hint that converts to the stored :delay in seconds --
  # see app/models/hint.rb).
  def hint_params
    params.fetch(:hint, ActionController::Parameters.new).permit(:text, :delay_in_minutes)
  end
end
