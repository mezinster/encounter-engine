# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!

# The Merb-era specs (~185 assertions) use `.should`/`.should_not`. Converting
# them to `expect` syntax is not this task's job -- mirror what the Merb
# spec_helper enabled so they keep running under RSpec 3.
require 'rspec/expectations'

# The model specs depend on factory helpers the Merb spec_helper used to load
# from spec/spec_helpers/. merb_matchers.rb (be_successful/redirect_to for
# Merb response objects) is gone -- the controller specs it was written for
# now use Rails' own have_http_status/redirect_to matchers instead.
require Rails.root.join('spec/spec_helpers/fixtures_helper')
require Rails.root.join('spec/spec_helpers/mailer_helper')
require Rails.root.join('spec/spec_helpers/exceptions_helper')

require_relative "support/query_counter"

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
# Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# Checks for pending migrations and applies them before tests are run.
# If you are not using ActiveRecord, you can remove these lines.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end
RSpec.configure do |config|
  # Mirrors the (now-replaced) Merb spec_helper, which enabled `should` syntax.
  # ~185 existing assertions use `x.should == y` / `x.should be_truthy`;
  # converting them to `expect` is explicitly not part of this task.
  config.expect_with :rspec do |expectations|
    expectations.syntax = [:should, :expect]
  end
  config.mock_with :rspec do |mocks|
    mocks.syntax = [:should, :expect]
  end

  config.include FixturesHelper
  config.include MailerHelper
  config.include ExceptionsHelper
  config.include ActiveSupport::Testing::TimeHelpers

  # Rate-limit counters live in Rails.cache, which is process-global and does
  # NOT roll back with the database transaction around each example. Without
  # this the first example to trip a limit leaves the counter set and a later
  # one starts mid-window -- an order-dependent failure, the kind that only
  # appears when someone runs the suite with a different seed.
  config.before(:each) { Rails.cache.clear }

  # Active Storage's :test service writes real bytes to tmp/storage. Specs in
  # this suite attach real files, so without this they accumulate across runs.
  config.after(:each) do
    FileUtils.rm_rf(Rails.root.join("tmp/storage"))
  end

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/7-1/rspec-rails
  #
  # You can also this infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Layout examples drive a real headless browser (spec/layout), because
  # neither suite can see layout: Capybara's rack_test driver parses no CSS at
  # all, so a play screen can be "green" while half of it hangs below the
  # phone's screen -- which is exactly what shipped. They are excluded from an
  # ordinary run because the browser binary is a developer-machine dependency
  # (~/.cache/ms-playwright) that CI does not install.
  #
  # Excluded, NOT skipped, and the difference is the point: an excluded example
  # is not counted or reported, so it cannot masquerade as a pass the way the
  # countdown examples did for a fortnight (see the shared.countdown note in
  # CLAUDE.md). When they DO run, a missing browser raises.
  #
  #   bin/measure-play-screen        # or: LAYOUT_SPECS=1 bundle exec rspec spec/layout
  # .present?, not mere truthiness: "" is truthy in Ruby, so a CI job that
  # exported LAYOUT_SPECS= or LAYOUT_SPECS=0 -- the ordinary way to say "off" in
  # a shell -- would un-exclude these and take the whole suite red on the
  # deliberate "no chrome-headless-shell found" raise.
  config.filter_run_excluding :layout => true unless ENV["LAYOUT_SPECS"].present?

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
