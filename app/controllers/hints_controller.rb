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
  before_action :ensure_editing_not_locked
  before_action :ensure_game_was_not_started, only: [:new, :create, :edit, :update]

  def new
  end

  def create
    if @hint.save
      apply_attached_files
      redirect_to [@game, @level]
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @hint.update(hint_attributes)
      apply_attached_files
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
    @hint = Hint.new(hint_attributes)
    @hint.level = @level
  end

  def find_level
    @level = Level.find(params[:level_id])
  end

  def find_game
    @game = @level.game
  end

  # Scoped through @level (same shape/fix as LevelsController#find_level):
  # @level is looked up first (from params[:level_id]) and @game is derived
  # from it, so ensure_author/ensure_editing_not_locked/
  # ensure_game_was_not_started all authorize against the level's real game --
  # but an unscoped Hint.find(params[:id]) here would still let a request
  # attach its own (authorized) level_id to someone else's hint id and edit or
  # delete it regardless of which level actually owns it.
  def find_hint
    @hint = @level.hints.find(params[:id])
  end

  # app/views/hints/_form.html.erb submits :text and :delay_in_minutes (a
  # virtual setter on Hint that converts to the stored :delay in seconds --
  # see app/models/hint.rb).
  def hint_params
    params.fetch(:hint, ActionController::Parameters.new)
          .permit(:text, :delay_in_minutes, :game_file_ids => [],
                  :translations => translation_params_shape(Hint::TRANSLATABLE_FIELDS))
  end

  # params.permit cannot express "any locale key", so build the shape from the
  # locales this platform actually knows.
  def translation_params_shape(fields)
    I18n.available_locales.map(&:to_s).index_with { fields.map(&:to_sym) }
  end

  # translations_attributes= is the concern's writer; the form posts
  # `translations` because that is what reads naturally in the markup.
  #
  # game_file_ids is deleted here, NOT merely left unmerged: this same method
  # feeds both Hint.new (build_hint, for :new AND :create) and Hint#update, and
  # passing it straight through would resolve to the through-association's own
  # generated game_file_ids=, which writes every row with NO locale --
  # collapsing every language's strip into one, silently. It is applied
  # separately, after a successful save, by apply_attached_files below.
  def hint_attributes
    attributes = hint_params.to_h
    attributes.delete("game_file_ids")
    translations = attributes.delete("translations")
    attributes.merge("translations_attributes" => translations)
  end

  # Unlike LevelsController, this runs on BOTH create and update: hints/_form
  # is one partial shared by hints/new and hints/edit, so the picker (and its
  # game_file_ids param) can arrive from either action.
  #
  # `hint_params.key?(:game_file_ids)` is the load-bearing check, not merely a
  # nil-guard -- see the identical comment on LevelsController#apply_attached_files
  # for why "key absent from params" must be a no-op rather than a wipe: the
  # picker always posts an array via its hidden fallback field, but a request
  # missing the key entirely (this tab's picker never rendered, or never
  # submitted) must leave every existing slot untouched.
  def apply_attached_files
    return unless hint_params.key?(:game_file_ids)

    @hint.replace_attached_files(hint_params[:game_file_ids], attachment_slot_locale)
  end

  # The exact expression hints/_form.html.erb uses to pick the active tab,
  # rerun here on the SAME params[:tab] the form's hidden field carried
  # forward. The primary tab manages the language-neutral slot (locale nil);
  # every other tab maps straight through as that locale's own slot.
  def attachment_slot_locale
    active_locale = params[:tab].presence_in(@level.game.available_locale_list) ||
                    @level.game.primary_locale
    active_locale == @level.game.primary_locale ? nil : active_locale
  end
end
