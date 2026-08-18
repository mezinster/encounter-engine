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
    @content_locales[game] ||= begin
      offered = game.available_locale_list
      candidate = per_game_content_locale(game) || current_content_user_locale
      offered.include?(candidate.to_s) ? candidate.to_s : game.primary_locale.to_s
    end
  end

  # Persist a per-game content-language choice for the signed-in user.
  # Returns false, writing nothing, for a guest or for a locale the game does
  # not offer.
  #
  # Both switchers write through this. They differ only in which filters guard
  # them and where they redirect; a second copy of the find_or_initialize would
  # be a second place to forget the available_locale_list check.
  def store_content_locale(game, locale)
    return false unless respond_to?(:current_user, true) && current_user
    return false unless game.available_locale_list.include?(locale.to_s)

    preference = GameLocalePreference.find_or_initialize_by(:user_id => current_user.id,
                                                           :game_id => game.id)
    preference.locale = locale.to_s
    preference.save!
    # content_locale_for memoises per game for the life of the request. Both
    # callers redirect, so nothing re-reads it here today -- but a stale
    # memo is exactly the kind of thing a later render would inherit silently.
    @content_locales = nil
    true
  end

  def per_game_content_locale(game)
    return nil unless respond_to?(:current_user, true) && current_user

    GameLocalePreference.find_by(:user_id => current_user.id, :game_id => game.id)&.locale
  end

  # LocaleSelection has already resolved ?locale= -> the user's stored
  # preference -> the instance default into I18n.locale, and wrapped the action
  # in I18n.with_locale. Reading current_user.locale directly here would
  # reimplement half of that and ignore ?locale= for signed-in users only,
  # so an organiser previewing with ?locale=en would get English chrome and
  # Russian tasks while a signed-out visitor got English both.
  def current_content_user_locale
    I18n.locale.to_s
  end
end
