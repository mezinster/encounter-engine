require "rails_helper"

# Rails 8.1's load_defaults sets action_on_path_relative_redirect = :raise:
# redirect_to with a URL that has neither a scheme nor a leading slash
# ("evil.example/phish") raises PathRelativeRedirectError instead of being
# glued onto the request host. Before 8.1 the default was :log.
#
# This is a second layer, not the first. Under :log the string still becomes
# "http://www.example.comevil.example/phish", whose host differs from the
# request's, so the open-redirect protection this app has had since the 7.0
# defaults (raise_on_open_redirects) raises OpenRedirectError for it anyway.
# That is why the expectation names the subclass: asserting the shared
# parent, UnsafeRedirectError, passed with the 8.1 setting reverted -- the
# older layer satisfied it -- and so proved nothing about this one.
#
# No controller in this app redirects to such a string today (every
# redirect_to is a route helper, a record, an array or a "/" path), so
# nothing exercises the setting by accident. This spec does, on purpose.
describe "path-relative redirects", :type => :request do
  probe = Class.new(ActionController::Base) do
    def relative; redirect_to "evil.example/phish"; end
    def absolute; redirect_to "/games"; end
  end

  before { stub_const("PathRelativeRedirectProbeController", probe) }

  around do |example|
    with_routing do |set|
      set.draw do
        get "/probe/relative" => "path_relative_redirect_probe#relative"
        get "/probe/absolute" => "path_relative_redirect_probe#absolute"
      end
      example.run
    end
  end

  it "raises PathRelativeRedirectError on a target with no scheme and no leading slash" do
    expect { get "/probe/relative" }
      .to raise_error(ActionController::Redirecting::PathRelativeRedirectError)
  end

  it "still allows an ordinary path redirect" do
    get "/probe/absolute"
    expect(response).to redirect_to("/games")
  end
end
