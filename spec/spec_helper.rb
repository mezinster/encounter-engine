# -*- encoding : utf-8 -*-
require "rubygems"

# Add the local gems dir if found within the app root; any dependencies loaded
# hereafter will try to load from the local gems before loading system gems.
if (local_gem_dir = File.join(File.dirname(__FILE__), '..', 'gems')) && $BUNDLE.nil?
  $BUNDLE = true; Gem.clear_paths; Gem.path.unshift(local_gem_dir)
end

require "merb-core"
require "rspec"

# this loads all plugins required in your init file so don't add them
# here again, Merb will do it for you
Merb.start_environment(:testing => true, :adapter => 'runner', :environment => ENV['MERB_ENV'] || 'test')

RSpec.configure do |config|
  # Merb::Test::ViewHelper is defined in merb-core/test/matchers.rb, which does
  # not load under RSpec 3 (see spec/spec_helpers/merb_matchers.rb). No spec in
  # this suite uses it, so it is simply dropped. RouteHelper and ControllerHelper
  # come from merb-core/test/helpers.rb and are RSpec-independent.
  config.include(Merb::Test::RouteHelper)
  config.include(Merb::Test::ControllerHelper)

  # The suite carries ~185 `.should` assertions written against RSpec 1.x.
  # Enabling both syntaxes keeps them passing so the runner upgrade stays
  # separable from converting assertions to `expect`.
  config.expect_with :rspec do |expectations|
    expectations.syntax = [:should, :expect]
  end

  config.mock_with :rspec do |mocks|
    mocks.syntax = [:should, :expect]
  end
end

glob = Merb.root / 'spec' / 'spec_helpers' / '**' / '*.rb'
Dir.glob(glob).each do |file|
  require file
end

include FixturesHelper
include MailerHelper
include ExceptionsHelper

ActiveRecordHelper.recreate_database!
