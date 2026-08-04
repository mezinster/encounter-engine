module LocaleSelection
  extend ActiveSupport::Concern

  included do
    before_action :set_locale
    around_action :use_locale
  end

  private

  # Precedence: explicit ?locale= (lets an organiser preview), then the signed-in
  # user's stored preference, then the instance default from DEFAULT_LOCALE.
  # Game content is never translated, so this only affects platform chrome.
  def set_locale
    @locale = requested_locale || current_user_locale || I18n.default_locale
  end

  def use_locale(&block)
    I18n.with_locale(@locale, &block)
  end

  def requested_locale
    candidate = params[:locale].presence&.to_sym
    candidate if I18n.available_locales.include?(candidate)
  end

  def current_user_locale
    return nil unless respond_to?(:current_user, true) && current_user

    candidate = current_user.locale.presence&.to_sym
    candidate if I18n.available_locales.include?(candidate)
  end
end
