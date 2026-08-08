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

  # Without this, I18n.t("bogus.key") silently returns
  # "Translation missing: ru.bogus.key" instead of raising -- and that
  # string is exactly what a template renders for the same missing key, so
  # `expect(rendered).to include(I18n.t(key))` passes even when key exists
  # nowhere. Raising here turns a silent typo into a loud test failure.
  config.i18n.raise_on_missing_translations = true

  # bcrypt's default cost is tuned to make offline brute force expensive in
  # production; the same cost applied to every fixture user in the suite is
  # what pushed a ~24s RSpec run past five minutes once User#encrypt_password
  # started hashing with it. MIN_COST keeps hashing cheap for tests only --
  # this file is test-environment-only, so production keeps the real default.
  BCrypt::Engine.cost = BCrypt::Engine::MIN_COST
end
