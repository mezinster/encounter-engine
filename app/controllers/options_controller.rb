# -*- encoding : utf-8 -*-
# Authoring the choices for a quiz question.
#
# Structured exactly like AnswersController -- same filters, same lookup chain,
# same GET delete. Options are the quiz counterpart of answer codes, so they
# get the counterpart page rather than a new pattern.
class OptionsController < ApplicationController
  include SecurityFilters

  before_action :find_game
  before_action :ensure_author
  before_action :ensure_editing_not_locked
  before_action :find_level
  before_action :find_question
  before_action :find_options
  before_action :find_option, only: [:delete]
  before_action :build_option, only: [:index, :create]

  def index
  end

  def create
    if @option.save
      redirect_to game_level_question_options_path(@game, @level, @question)
    else
      render :index, status: :unprocessable_entity
    end
  end

  # Unlike AnswersController#delete there is no "keep at least one" guard: a
  # question with no options is simply a code question again, which is a valid
  # state rather than a broken one.
  def delete
    @option.destroy
    redirect_to game_level_question_options_path(@game, @level, @question)
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  # Scoped through the game (same shape/fix as LevelsController#find_level):
  # ensure_author and ensure_editing_not_locked authorize against @game from
  # params[:game_id]. An unscoped lookup here would let a request pair its own
  # game_id with someone else's level_id.
  def find_level
    @level = @game.levels.find(params[:level_id])
  end

  # Scoped through @level, which is itself scoped through @game above -- a
  # question_id belonging to another level (or game) 404s instead of being
  # editable.
  def find_question
    @question = @level.questions.find(params[:question_id])
  end

  # Scoped through @options (find_options, above in the filter chain), which
  # is itself scoped through @question -- an option id belonging to another
  # question 404s instead of being deletable.
  def find_option
    @option = @options.find(params[:id])
  end

  def find_options
    @options = @question.options.order(:position, :id)
  end

  def build_option
    @option = Option.new(option_params)
    @option.question = @question
  end

  def option_params
    params.fetch(:option, ActionController::Parameters.new).permit(:text, :is_correct)
  end
end
