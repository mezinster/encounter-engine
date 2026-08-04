Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.force_ssl = true

  # kamal-proxy terminates TLS and forwards plain HTTP. Without assume_ssl,
  # force_ssl sees an HTTP request, redirects to HTTPS, and loops forever.
  config.assume_ssl = true

  # Containers have no useful filesystem for logs: log/production.log is
  # invisible to `docker logs` and discarded on redeploy.
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = :info

  config.i18n.default_locale = ENV.fetch("DEFAULT_LOCALE", "ru").to_sym

  config.action_mailer.delivery_method = :smtp
  # Welcome letters and invitations contain links; without a host they render
  # broken or raise.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("APP_HOST"), protocol: "https"
  }
  config.action_mailer.smtp_settings = {
    address:              ENV.fetch("SMTP_ADDRESS", "smtp.gmail.com"),
    port:                 ENV.fetch("SMTP_PORT", "587").to_i,
    authentication:       :plain,
    enable_starttls_auto: true,
    user_name:            ENV.fetch("SMTP_USERNAME"),
    password:             ENV.fetch("SMTP_PASSWORD"),
    domain:               ENV.fetch("APP_HOST")
  }
end
