# Mirrors LocaleSelection: a per-user preference with an instance-wide
# fallback. Where that one wraps I18n.with_locale, this wraps Time.use_zone.
module TimeZoneSelection
  extend ActiveSupport::Concern

  included do
    # around_action, NOT before_action. Time.use_zone restores the previous
    # zone in an ensure block; assigning Time.zone in a before_action would
    # leak the last request's zone into whatever runs next on that thread.
    around_action :use_time_zone
  end

  private

  # Precedence: the signed-in user's stored preference, then the instance
  # default from config.time_zone (ENV["TZ"]).
  #
  # Deliberately no ?timezone= override. LocaleSelection has one so an
  # organiser can preview a translation; there is no equivalent need here.
  def use_time_zone(&block)
    Time.use_zone(current_user_time_zone || Time.zone, &block)
  end

  # ActiveSupport::TimeZone[] returns nil for a name it does not know, so one
  # expression covers both "not set" and "no longer valid". Defensive in the
  # same shape as LocaleSelection#current_user_locale: a stored zone can go
  # stale when the tzdata Rails ships changes, and a profile column must never
  # be able to 500 every page the user visits.
  def current_user_time_zone
    return nil unless respond_to?(:current_user, true) && current_user

    ActiveSupport::TimeZone[current_user.timezone.to_s]
  end
end
