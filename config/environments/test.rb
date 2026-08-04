Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.action_dispatch.show_exceptions = :none
  config.action_controller.allow_forgery_protection = false
  config.action_mailer.delivery_method = :test
  config.active_support.deprecation = :stderr

  # The 59 feature files assert Russian UI copy. Pinning the locale here is
  # what lets them stay byte-identical while the app becomes translatable.
  config.i18n.default_locale = :ru
end
