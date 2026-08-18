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
      apply_attached_files
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

  # Scoped through the game, not Level.find: ensure_author and
  # ensure_game_was_not_started both authorize against @game, which comes from
  # params[:game_id]. An unscoped lookup lets a request pair its own game_id
  # with someone else's level_id and pass every filter -- verified reachable
  # before this was fixed.
  def find_level
    @level = @game.levels.find(params[:id])
  end

  # correct_answer is Level's virtual setter (see app/models/level.rb) that
  # builds the level's first Question/Answer pair -- only submitted by the
  # "new level" form, not by "edit", but it's harmless to permit on both.
  def level_params
    params.fetch(:level, ActionController::Parameters.new)
          .permit(:name, :text, :correct_answer, :wrong_answer_penalty_in_minutes,
                  :any_code_passes, :points_award, :game_file_ids => [],
                  :translations => translation_params_shape(Level::TRANSLATABLE_FIELDS))
  end

  # params.permit cannot express "any locale key", so build the shape from the
  # locales this platform actually knows.
  def translation_params_shape(fields)
    I18n.available_locales.map(&:to_s).index_with { fields.map(&:to_sym) }
  end

  # translations_attributes= is the concern's writer; the form posts
  # `translations` because that is what reads naturally in the markup.
  #
  # game_file_ids is deleted here, NOT merely left unmerged: passing it
  # straight to Level#update would resolve to the through-association's own
  # generated game_file_ids=, which writes every row with NO locale --
  # collapsing every language's strip into one, silently, and defeating
  # Task 1's whole per-locale design. It is applied separately, after a
  # successful save, by apply_attached_files below.
  def level_attributes
    attributes = level_params.to_h
    attributes.delete("game_file_ids")
    translations = attributes.delete("translations")
    attributes.merge("translations_attributes" => translations)
  end

  # Runs only on update -- levels/new.html.erb has no picker (a level's file
  # library only makes sense once the level itself exists), so create never
  # posts game_file_ids and never needs this.
  #
  # `level_params.key?(:game_file_ids)` is the load-bearing check, not merely
  # a nil-guard: the picker always posts an array (see the hidden fallback
  # field in game_files/_picker.html.erb), but if the key is missing from the
  # request entirely -- this tab's picker was never rendered, or never
  # submitted -- calling replace_attached_files anyway would WIPE that slot
  # (both nil and [] mean "clear it" to the model, which cannot tell "author
  # unticked everything" from "this section was never on the page"). Absent
  # key -> no-op is what protects every locale tab the author did not open
  # this request.
  def apply_attached_files
    return unless level_params.key?(:game_file_ids)

    @level.replace_attached_files(level_params[:game_file_ids], attachment_slot_locale)
  end

  # The exact expression levels/edit.html.erb uses to pick the active tab,
  # rerun here on the SAME params[:tab] the form's hidden field carried
  # forward -- one source of truth for "which tab is this", not a second one
  # that could drift from the view's. The primary tab manages the
  # language-neutral slot (locale nil, FileAttachable's contract); every
  # other tab maps straight through as that locale's own slot.
  def attachment_slot_locale
    active_locale = params[:tab].presence_in(@level.game.available_locale_list) ||
                    @level.game.primary_locale
    active_locale == @level.game.primary_locale ? nil : active_locale
  end
end
