# -*- encoding : utf-8 -*-
# Sets up the Merb environment for Cucumber (thanks to krzys and roman)
require "rubygems"

require "merb-core"
require 'rspec/expectations'
require 'rspec/mocks'
# merb_cucumber/world/base.rb mixes in Merb::Test::Matchers and
# Merb::Test::ViewHelper. Both are defined by merb-core's RSpec 1 bridge
# (test_ext/rspec.rb and matchers.rb), which no longer loads under RSpec 3.
# They are reproduced here: Matchers was always an empty marker module, and
# ViewHelper is nothing but the two Webrat mixins below.
require "webrat"
module Merb
  module Test
    module Matchers; end

    module ViewHelper
      include ::Webrat::Matchers
      include ::Webrat::HaveTagMatcher
    end
  end
end

require "merb_cucumber/world/webrat"
require "merb_cucumber/helpers/activerecord"

# The step definitions use RSpec 1.x `.should` assertions. RSpec 3 keeps that
# syntax available but it must be switched on explicitly.
RSpec::Expectations::Syntax.enable_should

# Steps need `match` and `be_empty` from RSpec::Matchers, but RSpec::Matchers
# also defines `within` (part of the be_within composable-matcher DSL), which
# collides with Webrat's within(selector) page-scoping helper. Cucumber extends
# World modules onto the world object, so RSpec's `within` would sit on the
# singleton and beat Webrat's in the class chain — silently turning
# `within("#game-1") { click_link "..." }` into a no-op that returns a matcher.
# Delegating explicitly keeps `within` with Webrat.
module MatchersForCucumber
  include RSpec::Matchers

  def within(*args, &block)
    Webrat::Methods.instance_method(:within).bind(self).call(*args, &block)
  end
end
World(MatchersForCucumber)

# rspec-mocks is not driven by rspec-core here, so each scenario has to open
# and close its own mock scope (features/steps/time_steps.rb stubs Time.now).
World(RSpec::Mocks::ExampleMethods)
Before { RSpec::Mocks.setup }
After { RSpec::Mocks.teardown }

# Recursively Load all steps defined within features/**/*_steps.rb
Dir["#{Merb.root}" / "features" / "**" / "*_steps.rb"].each { |f| require f }

# Uncomment if you want transactional fixtures
# Merb::Test::World::Base.use_transactional_fixtures

Merb.start_environment(:testing => true, :adapter => 'runner', :environment => ENV['MERB_ENV'] || 'test')
