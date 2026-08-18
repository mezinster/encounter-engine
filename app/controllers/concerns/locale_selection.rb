module LocaleSelection
  extend ActiveSupport::Concern

  included do
    before_action :set_locale
    around_action :use_locale
  end

  private

  # Precedence: explicit ?locale=, then the choice that ?locale= left in the
  # session, then the signed-in user's stored preference, then the instance
  # default from DEFAULT_LOCALE. Game content is never translated, so this only
  # affects platform chrome.
  #
  # ?locale= is remembered because on its own it lasted exactly one page view:
  # no form in this app carries the parameter through its POST, so the first
  # button pressed after switching threw the language away. That was invisible
  # to both suites, which assert on one response at a time.
  #
  # Remembering it in the session and not in the user row is deliberate. A
  # guest has no row (the redemption and signup screens are the ones that
  # matter), and for a signed-in user the profile form is still where a lasting
  # choice is made -- so saving that form clears this key rather than losing to
  # it (UsersController#update). reset_session on login and on logout drops it
  # too, which is why logging in gives you the account's own preference.
  def set_locale
    requested = requested_locale
    session[:locale] = requested.to_s if requested

    @locale = requested || session_locale || current_user_locale || I18n.default_locale
  end

  def use_locale(&block)
    I18n.with_locale(@locale, &block)
  end

  def requested_locale
    candidate = params[:locale].presence&.to_sym
    candidate if I18n.available_locales.include?(candidate)
  end

  # Re-validated on every read, not trusted from when it was written: the list
  # of available locales can shrink between one request and the next, and this
  # value rides in a cookie the client holds.
  def session_locale
    candidate = session[:locale].presence&.to_sym
    candidate if I18n.available_locales.include?(candidate)
  end

  def current_user_locale
    return nil unless respond_to?(:current_user, true) && current_user

    candidate = current_user.locale.presence&.to_sym
    candidate if I18n.available_locales.include?(candidate)
  end
end
