# app/models/game_locale_preference.rb
#
# A player's per-game override of their own content language. Stored rather
# than kept in the session so a player switching device mid-race keeps it.
class GameLocalePreference < ApplicationRecord
  belongs_to :user
  belongs_to :game

  validates :locale, presence: true
end
