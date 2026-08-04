require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

Bundler.require(*Rails.groups)

module EncounterEngine
  class Application < Rails::Application
    config.load_defaults 8.0

    # Platform copy is translated; game content is not. See config/locales.
    #
    # Target set is en, ru, uk, ka -- the communities this platform serves.
    # uk and ka are registered now (locale files exist, available here) but
    # not yet translated beyond the language-name keys the switcher needs to
    # label them; config.i18n.fallbacks below sends every other key to :ru
    # until that translation work happens (task 12 brief, "register them now,
    # translate later"). Flipping the *default* to :en is a separate decision
    # the project owner has deferred to when the content-translation work
    # happens -- do not change it here.
    config.i18n.default_locale = :ru
    config.i18n.available_locales = [:ru, :en, :uk, :ka]
    config.i18n.fallbacks = [:ru]

    # Each deployment serves one city, so the zone is per-instance, matching
    # the TZ variable create-heroku-instance already sets.
    config.time_zone = ENV.fetch("TZ", "UTC")
    config.active_record.default_timezone = :utc
  end
end
