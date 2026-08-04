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

# webrat/integrations/merb.rb reopens Merb::Test::RequestHelper and overrides
# #request to call Webrat::MerbAdapter#request. That adapter has no such method
# -- RackAdapter only delegates get/post/put/delete to its Rack::Test session --
# so every request spec raises NoMethodError. The integration shim was never
# updated for the Rack::Test-based adapter.
#
# Removing the override lets the included Merb::Test::MakeRequest#request show
# through again, which is the (uri, env) signature these specs are written
# against. Nothing in features/ calls request(), so Cucumber is unaffected.
if Merb::Test::RequestHelper.instance_methods(false).map(&:to_sym).include?(:request)
  Merb::Test::RequestHelper.send(:remove_method, :request)
end

# Merb 1.1 predates Rack 2, and merb-core.gemspec depends on rack with no
# version constraint, so this app runs it against Rack 2.2. Rack 1.x could hand
# back the Set-Cookie header as an Array; Rack 2 always returns a String, with
# multiple cookies newline-separated. Merb::Test::CookieJar#update calls
# raw_cookies.each, so any request spec whose response sets a cookie dies on
# String#each. Normalise before Merb sees it.
module MerbCookieJarRackCompat
  def update(jar, uri, raw_cookies)
    raw_cookies = raw_cookies.split("\n") if raw_cookies.is_a?(String)
    super(jar, uri, raw_cookies)
  end
end
Merb::Test::CookieJar.prepend(MerbCookieJarRackCompat)

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
