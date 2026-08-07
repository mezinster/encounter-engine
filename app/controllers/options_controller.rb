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
  before_action :set_active_locale, only: [:index]

  def index
  end

  # Options carry a translatable `text`, so Game#missing_translations demands
  # one per declared locale before a multilingual game may leave draft -- but
  # until this existed there was no screen on which to provide it. A bilingual
  # game with a quiz level could not be published by any sequence of author
  # actions.
  #
  # A bulk write rather than one form per option: an author translating a
  # question's choices is doing one task, and three round-trips for three
  # options is three chances to leave the set half-translated.
  def translations
    locale = params[:locale].to_s
    unless @game.available_locale_list.include?(locale)
      redirect_to game_level_question_options_path(@game, @level, @question) and return
    end

    submitted = params.fetch(:option_translations, {})
    submitted = {} unless submitted.respond_to?(:each_pair)

    @options.each do |option|
      value = submitted[option.id.to_s]
      next if value.nil?

      option.translations_attributes = { locale => { "text" => value.to_s } }
      option.save!
    end

    redirect_to game_level_question_options_path(@game, @level, @question, :tab => locale),
                :notice => t("options.index.translations_saved")
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

  # Mirrors hints/levels: ?tab= selects the language being edited, deliberately
  # distinct from the header's ?locale= chrome switcher.
  def set_active_locale
    @active_locale = params[:tab].presence_in(@game.available_locale_list) || @game.primary_locale
  end

  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_level
    @level = Level.find(params[:level_id])
  end

  def find_question
    @question = Question.find(params[:question_id])
  end

  def find_option
    @option = Option.find(params[:id])
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
