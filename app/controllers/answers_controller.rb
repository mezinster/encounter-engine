# -*- encoding : utf-8 -*-
class AnswersController < ApplicationController
  include SecurityFilters

  before_action :find_game
  before_action :ensure_author
  before_action :ensure_editing_not_locked
  before_action :find_level
  before_action :find_question
  before_action :find_answers
  before_action :find_answer, only: [:delete]
  before_action :build_answer, only: [:index, :create]

  def index
  end

  def create
    if @answer.save
      redirect_to game_level_question_answers_path(@game, @level, @question)
    else
      render :index, status: :unprocessable_entity
    end
  end

  def delete
    if @answers.count > 1
      @answer.destroy
      redirect_to game_level_question_answers_path(@game, @level, @question)
    else
      build_answer
      @answer.errors.add(:question, t("answers.must_have_at_least_one_variant"))
      render :index, status: :unprocessable_entity
    end
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

  # Scoped through @answers (find_answers, above in the filter chain), which
  # is itself scoped through @question -- an answer id belonging to another
  # question 404s instead of being deletable.
  def find_answer
    @answer = @answers.find(params[:id])
  end

  def find_answers
    @answers = Answer.of_question(@question)
  end

  # app/views/answers/index.html.erb's "add another code" form only submits
  # :value.
  def build_answer
    @answer = Answer.new(answer_params)
    @answer.level = @level
    @answer.question = @question
  end

  def answer_params
    params.fetch(:answer, ActionController::Parameters.new).permit(:value)
  end
end
