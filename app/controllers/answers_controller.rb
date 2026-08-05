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

  def find_level
    @level = Level.find(params[:level_id])
  end

  def find_question
    @question = Question.find(params[:question_id])
  end

  def find_answer
    @answer = Answer.find(params[:id])
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
