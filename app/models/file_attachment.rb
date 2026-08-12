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

    return if owning_game.nil? || owning_game == game_file.game

    errors.add(:game_file, :inclusion)
  end
end
