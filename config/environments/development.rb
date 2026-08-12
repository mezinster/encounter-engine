Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_mailer.delivery_method = :test
  config.active_support.deprecation = :log

  config.active_storage.service = :local
  config.active_job.queue_adapter = :inline
end
