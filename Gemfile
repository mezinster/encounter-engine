source "https://rubygems.org"

ruby "3.3.12"

gem "rails", "8.0.5.1"
# Floor, not a feature pin: rack 3.2.6 is the version whose Rack::Sendfile
# stopped reading the client-supplied X-Sendfile-Type header (see the comment
# at the send_file call in app/controllers/file_deliveries_controller.rb) --
# below that version, a client claiming X-Sendfile-Type: X-Accel-Redirect
# gets the absolute storage path back instead of the file's bytes. This app
# sets no config.action_dispatch.x_sendfile_header, so rack's own fix is the
# only thing standing in the way of that; a plain rails dependency floor
# would let a future `bundle update` silently drop below it.
gem "rack", ">= 3.2.6"
# Rails' own per-locale defaults: date and time formats, ActiveRecord
# validation messages, and -- the reason this became urgent -- CLDR
# pluralisation rules. Without it Rails' built-in pluralizer knows one/other
# only, so the first pluralised key written in this app would raise
# I18n::InvalidPluralizationData in every Slavic locale.
#
# Load order matters and is in this app's favour: the gem's files enter
# I18n.load_path before config/locales/*.yml, so anything this repository
# defines still wins. The gem fills gaps; it never overrides.
gem "rails-i18n", "~> 8.0"
gem "sqlite3", "~> 2.0", group: [:development, :test]
gem "pg", group: :production
gem "puma"
gem "acts_as_list"
# Image canonicalisation for game file uploads: HEIC→JPEG, metadata stripping,
# and the web/thumb variants. `require: false` deliberately — ruby-vips binds
# to the system libvips through FFI at require time, so an eager require would
# turn a missing system library into a failure to BOOT rather than a failure to
# upload. See spec/image_processing_spec.rb.
gem "image_processing", "~> 1.13", require: false
gem "bcrypt", "~> 3.1"

group :development, :test do
  gem "rspec-rails", "~> 7.0"
  gem "pry"
  gem "pry-byebug"
  gem "kamal", "~> 2.0", require: false
end

group :test do
  gem "cucumber-rails", require: false
  gem "capybara"
  # Restores the bare `assigns(:x)` helper controller specs relied on before
  # Rails 5 split it out. Four ported specs need it for @answer/
  # @answer_was_correct etc. -- there's no equivalent way to read those
  # without it.
  gem "rails-controller-testing", "~> 1.0"
end
