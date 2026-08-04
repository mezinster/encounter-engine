Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.force_ssl = true
  config.log_level = :info
  config.action_mailer.delivery_method = :smtp
  config.i18n.default_locale = ENV.fetch("DEFAULT_LOCALE", "ru").to_sym
end
