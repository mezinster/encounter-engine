# -*- encoding : utf-8 -*-
#
# Cucumber bootstrap. Replaces the Merb one, which booted merb-core, mixed in
# merb_cucumber's Webrat world and rebuilt the database by hand.
#
# `cucumber/rails` boots config/environment (RAILS_ENV=test), installs the
# Capybara world (Capybara::DSL + Capybara::RSpecMatchers) and makes the World
# an ActionDispatch::IntegrationTest.
require "cucumber/rails"

# Let application exceptions reach Cucumber instead of being swallowed into a
# rendered 500 page -- a scenario must fail loudly on a server error.
ActionController::Base.allow_rescue = false

# The whole suite drives HTML over Rack; there is no JavaScript anywhere in
# this application, so the in-process driver is both correct and fast.
Capybara.default_driver = :rack_test

# The `должен увидеть "..."` steps assert one-line UI copy against a document
# whose text carries whatever indentation and line breaks the ERB templates
# happened to produce. Webrat's `contain` matched a raw HTML substring, so
# markup-internal whitespace never mattered; Capybara's text matchers compare
# rendered text verbatim unless told otherwise. Normalising whitespace on both
# sides restores the old, intended meaning: "does the page say this?".
Capybara.default_normalize_ws = true

# NB: Capybara.match is deliberately left at its default (:smart), so ambiguous
# buttons and form fields still raise Capybara::Ambiguous. The suite's only two
# ambiguities are duplicated navigation LINKS, and the tolerance for those is
# scoped to the one step that needs it -- see "иду по ссылке" in
# features/steps/webrat_steps.rb.

# Every feature file asserts Russian UI copy verbatim; that is what let all 59
# of them survive this migration byte-identical. config/environments/test.rb
# pins config.i18n.default_locale, this pins the per-scenario current locale
# (a step that renders under another locale must not leak into the next
# scenario).
Before { I18n.locale = :ru }

# --- Database isolation ------------------------------------------------------
#
# The Merb suite called ActiveRecordHelper.recreate_database! before every
# scenario (features/steps/before_steps.rb), dropping and recreating every
# table. That helper is gone with merb_cucumber.
#
# cucumber-rails only auto-manages the database when DatabaseCleaner is present
# (lib/cucumber/rails/hooks/database_cleaner.rb) -- it is not in the Gemfile --
# and its ActionDispatch::IntegrationTest world never runs Minitest's setup
# callbacks, so `use_transactional_tests` never fires either. Without this hook
# scenarios would share one ever-growing database and start colliding on the
# unique nickname/e-mail indexes.
#
# A rollback per scenario is equivalent to the old drop-and-recreate for these
# features and much faster. It also rewinds SQLite's AUTOINCREMENT counters,
# which recreate_database! did too -- several features rely on the first game
# created in a scenario having id 1.
Around do |_scenario, block|
  ActiveRecord::Base.transaction do
    block.call
    raise ActiveRecord::Rollback
  end
end

# The rollback above only undoes what a scenario itself did. `bundle exec rspec`
# shares db/test.sqlite3 and does leave rows behind, and the suite is not
# indifferent to that: with pre-existing games on the dashboard, "иду по ссылке
# 'Подать заявку на регистрацию'" clicks the first such link on the page, which
# then belongs to a stranger's game. So start the run from an empty database,
# exactly as recreate_database! used to guarantee.
#
# The identity counters have to go too, not just the rows: Rails declares
# SQLite primary keys AUTOINCREMENT, so a leftover counter would stop the first
# game of a scenario from getting id 1 -- and features/logs/log.feature:53-82
# passes only because game id 1 and level id 1 coincide there
# (app/views/logs/show_game_log.html.erb:7 passes a level to Log.of_game, which
# resolves to `where(game_id: level.id)`). That is load-bearing, so this must
# not fail quietly.
BeforeAll do
  connection = ActiveRecord::Base.connection
  keep = %w[schema_migrations ar_internal_metadata]

  connection.disable_referential_integrity do
    (connection.tables - keep).each do |table|
      connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
    end
  end

  reset_primary_key_sequences!(connection)
end

# Rewinds the database's identity counters. SQLite keeps them in the internal
# table sqlite_sequence, which is absent from #tables and #table_exists? and is
# only created once something has been inserted -- so "no such table" is the
# expected state on a virgin database and is the ONLY tolerated failure. Any
# other error, and any non-SQLite adapter, raises loudly rather than silently
# leaving the counters where they were.
def reset_primary_key_sequences!(connection)
  adapter = connection.adapter_name.downcase
  unless adapter.include?('sqlite')
    raise "features/support/env.rb resets AUTOINCREMENT counters via sqlite_sequence, " \
          "but the test database is #{connection.adapter_name}. Port this to that adapter " \
          "(see the comment above -- features/logs/log.feature depends on ids starting at 1)."
  end

  connection.execute('DELETE FROM sqlite_sequence')
rescue ActiveRecord::StatementInvalid => e
  raise unless e.message.include?('no such table: sqlite_sequence')
end

# --- Time travel -------------------------------------------------------------
#
# features/steps/time_steps.rb used to stub Time.now with rspec-mocks, which
# left Date.today and Time.zone.now on the real clock. Hints unlock on a delay
# and levels record entry times, so the app reads all three.
require "active_support/testing/time_helpers"
World(ActiveSupport::Testing::TimeHelpers)
After { travel_back }

# --- Matchers ----------------------------------------------------------------
#
# RSpec::Matchers is needed for `expect(...).to match(/../)` and friends, but it
# also defines `within` (the be_within composable-matcher DSL), which collides
# with Capybara's within(selector) page-scoping helper. Cucumber `extend`s World
# modules onto the world object one by one, later ones winning, so a bare
# World(RSpec::Matchers) after cucumber-rails' World(Capybara::DSL) would
# silently turn `within("#game-1") { click_link "..." }` into a no-op returning
# a matcher. Delegating explicitly keeps `within` with Capybara. (The Merb
# env.rb carried the same guard against Webrat's within.)
require "rspec/expectations"

module MatchersForCucumber
  include RSpec::Matchers

  def within(*args, &block)
    Capybara::DSL.instance_method(:within).bind(self).call(*args, &block)
  end
end
World(MatchersForCucumber)

# Recursively load all steps defined in features/**/*_steps.rb. config/cucumber.yml
# only auto-requires features/support, and features/step_definitions is
# gitignored, so the step files keep living beside the features they serve.
Dir[Rails.root.join("features", "**", "*_steps.rb").to_s].sort.each { |f| require f }
