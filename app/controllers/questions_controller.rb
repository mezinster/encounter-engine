# -*- encoding : utf-8 -*-
class QuestionsController < ApplicationController
  include SecurityFilters

  before_action :find_game
  before_action :ensure_author
  before_action :find_level
  before_action :build_question, only: [:new, :create]

  def new
  end

  def create
    if @question.save
      @answer = @question.answers.first

      if @answer.save
        redirect_to [@level.game, @level]
      else
        @question.destroy
        build_question
        render :new, status: :unprocessable_entity
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_level
    @level = Level.find(params[:level_id])
  end

  # app/views/questions/new.html.erb submits :correct_answer, Question's
  # virtual setter (see app/models/question.rb) that builds the question's
  # first Answer.
  def build_question
    @question = Question.new(question_params)
    @question.level = @level
  end

  def question_params
    params.fetch(:question, ActionController::Parameters.new).permit(:correct_answer)
  end
end
