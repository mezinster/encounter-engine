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

  # In-process, deliberately. This instance runs ONE Puma process in ONE
  # container -- there is no config/puma.rb and no WEB_CONCURRENCY in
  # config/deploy.yml -- so a process-local store is shared by every request
  # thread, which is all the rate limiter needs.
  #
  # The assumption is the whole justification, so it is written down: the day
  # this app gains `workers` or a second server, each process gets its own
  # counters and every configured limit silently multiplies by the process
  # count. That failure is invisible -- limits still "work", just N times
  # weaker. Changing either of those things means moving to a shared store (a
  # Redis/Valkey Kamal accessory is the clean option; solid_cache would put
  # cache churn into the WAL that wal-g ships to Azure Blob, which lengthens
  # restore replay -- see docs/runbooks/restore.md).
  #
  # Also replaces Rails' :file_store default, which wrote into a container
  # filesystem that is discarded on every deploy anyway.
  #
  # The limiter keys on request.remote_ip. Behind kamal-proxy every connection
  # arrives from the proxy container, and remote_ip is only correct if
  # ActionDispatch::RemoteIp trusts that hop and reads X-Forwarded-For. It
  # should: the proxy connects over the Docker bridge (a private address), and
  # Rails trusts private ranges by default. "Should" is not evidence, and the
  # failure mode is the dangerous direction -- if XFF is ignored, EVERY request
  # looks like one client and the first few signups lock out the whole
  # internet.
  #
  # VERIFIED in production on 2026-08-09, before this shipped: a request from a
  # known public address was logged by Rails as that address, and other
  # concurrent requests logged as their own distinct public addresses.
  # (Rails::Rack::Logger's "Started ... for X" line IS request.remote_ip, so it
  # tests the exact expression the limiter uses.) Re-check if the proxy is
  # replaced, moved off the Docker bridge, or fronted by a CDN -- a CDN's
  # egress IP would become "the client" unless added to trusted_proxies.
  # RequestThrottling also logs remote_ip and X-Forwarded-For on every refusal,
  # so the check can be repeated at any time.
  # 32 MB written out, not 32.megabytes. config/application.rb requires
  # railties selectively rather than "rails/all", so active_support/all is
  # never loaded, and an environment file is evaluated during initialize!
  # before whichever component would have pulled in the numeric/bytes core
  # extension. `32.megabytes` therefore raises NoMethodError on Integer here,
  # while working fine anywhere that runs after boot -- which is why neither
  # suite caught it (both run in the test environment, and this file is only
  # read in production). The image smoke test did.
  config.cache_store = :memory_store, { :size => 32 * 1024 * 1024 }

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
