# Which language a player reads a given game's CONTENT in.
#
# Deliberately separate from LocaleSelection, which picks the platform chrome
# locale. The two are independent: a Georgian speaker browsing a Russian-only
# game gets Georgian menus and Russian tasks, because that is the best
# available answer rather than a compromise between them.
module ContentLocaleSelection
  extend ActiveSupport::Concern

  included do
    helper_method :content_locale_for
  end

  private

  # Precedence: the player's explicit per-game choice, then their own locale
  # (which LocaleSelection has already resolved from ?locale= or their
  # profile), then the game's primary language.
  def content_locale_for(game)
    return nil if game.nil?

    @content_locales ||= {}
    @content_locales[game.id] ||= begin
      offered = game.available_locale_list
      candidate = per_game_content_locale(game) || current_content_user_locale
      offered.include?(candidate.to_s) ? candidate.to_s : game.primary_locale.to_s
    end
  end

  def per_game_content_locale(game)
    return nil unless respond_to?(:current_user, true) && current_user

    GameLocalePreference.find_by(:user_id => current_user.id, :game_id => game.id)&.locale
  end

  def current_content_user_locale
    return I18n.locale.to_s unless respond_to?(:current_user, true) && current_user

    current_user.locale.presence || I18n.locale.to_s
  end
end
