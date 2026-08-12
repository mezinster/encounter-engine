# -*- encoding : utf-8 -*-
#
# Joins a GameFile to the Level or Hint that displays it.
class FileAttachment < ApplicationRecord
  belongs_to :game_file, :optional => true
  belongs_to :attachable, :polymorphic => true, :optional => true

  # Scoped to the owner AND the locale: a level's language-neutral list and
  # its English-only list are two independently ordered strips, not one list
  # with gaps.
  acts_as_list :scope => [ :attachable_type, :attachable_id, :locale ]

  validates :game_file, :presence => true
  validates :attachable, :presence => true
  validate  :locale_is_served
  validate  :file_belongs_to_the_same_game

  # Rows a player in `locale` should see: the language-neutral ones plus the
  # ones for their language. Written as an explicit NULL check rather than
  # where(:locale => [nil, locale]) so the intent survives a later edit.
  scope :for_locale, ->(locale) {
    where("locale IS NULL OR locale = ?", locale.to_s)
  }

  private

  def locale_is_served
    return if locale.blank?
    return if I18n.available_locales.map(&:to_s).include?(locale)

    errors.add(:locale, :inclusion)
  end

  # An author can only attach files from the game they are editing. Without
  # this the row would save and then serve nothing: the delivery controller
  # authorises by game, so a foreign file 404s for every player while looking
  # perfectly attached in the editor.
  def file_belongs_to_the_same_game
    return if game_file.nil? || attachable.nil?

    owning_game = case attachable
                  when Level then attachable.game
                  when Hint  then attachable.level&.game
                  end

    # Cannot verify -> refuse. An earlier draft returned early here, treating
    # "I cannot tell which game this belongs to" as "fine" -- which let a
    # foreign game's file attach to a hint with no level, or to any attachable
    # whose game chain did not resolve. A validator whose entire job is keeping
    # one game's files out of another game's levels must fail closed.
    #
    # Level always has a game (it validates presence). Hint does NOT validate
    # its level, so a level-less hint is schema-legal -- and attaching a file to
    # one is now invalid. That is the intended, narrow cost: such a hint is
    # never shown to any player, and phase 3 builds these records from a
    # persisted level or hint inside the game being edited, so the real flow
    # never reaches this branch.
    if owning_game.nil?
      errors.add(:attachable, :inclusion)
      return
    end

    return if owning_game == game_file.game

    errors.add(:game_file, :inclusion)
  end
end
