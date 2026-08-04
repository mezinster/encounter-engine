# -*- encoding : utf-8 -*-
# Go to http://wiki.merbivore.com/pages/init-rb

use_orm :activerecord
use_test :rspec
use_template_engine :erb

# The session cookie is signed with this key. Anyone who knows it can forge a
# session for any user, so it must not live in the repository. Set it in the
# environment of every deployment:
#
#   heroku config:set SESSION_SECRET_KEY="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(40)')"
#
# Development, test and rake fall back to a fixed, publicly known value so the
# app runs from a fresh clone with no setup. Every other environment must
# supply its own — an unrecognised environment is treated as one that must.
# Merb rejects secrets shorter than 16 characters.
INSECURE_DEVELOPMENT_SESSION_SECRET = 'insecure-development-and-test-session-secret'
ENVIRONMENTS_ALLOWED_AN_INSECURE_SESSION_SECRET = %w(development test rake)

session_secret_key = ENV['SESSION_SECRET_KEY'].to_s

if session_secret_key.length < 16
  unless ENVIRONMENTS_ALLOWED_AN_INSECURE_SESSION_SECRET.include?(Merb.environment.to_s)
    raise "SESSION_SECRET_KEY is unset or shorter than 16 characters in the " \
          "'#{Merb.environment}' environment. Generate one with: " \
          "ruby -rsecurerandom -e 'puts SecureRandom.hex(40)'"
  end

  session_secret_key = INSECURE_DEVELOPMENT_SESSION_SECRET
end

Merb::Config.use do |c|
  c[:use_mutex] = false
  c[:session_store] = 'cookie'  # can also be 'memory', 'memcache', 'container', 'datamapper

  # cookie session store configuration
  c[:session_secret_key] = session_secret_key
  c[:session_id_key] = '_encounter-engine_session_id' # cookie session id key, defaults to "_session_id"
end

Merb.push_path(:lib, Merb.root / "lib", "*.rb")

Merb::BootLoader.before_app_loads do
  # This will get executed after dependencies have been loaded but before your app's classes have loaded.
end

Merb::BootLoader.after_app_loads do
  # This will get executed after your app's classes have been loaded.
  Merb::Mailer.delivery_method = :test_send
end

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
