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
  before_action :ensure_editing_not_locked
  before_action :ensure_game_was_not_started, only: [:new, :create, :edit, :update, :delete]
  before_action :find_level, except: [:new, :create]

  def new
    @level = @game.levels.build
  end

  def create
    @level = @game.levels.build(level_attributes)

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
    if @level.update(level_attributes)
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
          .permit(:name, :text, :correct_answer, :wrong_answer_penalty_in_minutes,
                  :any_code_passes,
                  :translations => translation_params_shape(Level::TRANSLATABLE_FIELDS))
  end

  # params.permit cannot express "any locale key", so build the shape from the
  # locales this platform actually knows.
  def translation_params_shape(fields)
    I18n.available_locales.map(&:to_s).index_with { fields.map(&:to_sym) }
  end

  # translations_attributes= is the concern's writer; the form posts
  # `translations` because that is what reads naturally in the markup.
  def level_attributes
    attributes = level_params.to_h
    translations = attributes.delete("translations")
    attributes.merge("translations_attributes" => translations)
  end
end
