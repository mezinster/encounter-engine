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
    config.i18n.default_locale = :ru
    config.i18n.available_locales = [:ru, :en]
    config.i18n.fallbacks = [:ru]

    # Each deployment serves one city, so the zone is per-instance, matching
    # the TZ variable create-heroku-instance already sets.
    config.time_zone = ENV.fetch("TZ", "UTC")
    config.active_record.default_timezone = :utc
  end
end
