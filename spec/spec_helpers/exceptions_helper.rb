# -*- encoding : utf-8 -*-
#
# Merb raised Unauthenticated/Unauthorized straight through to the test, so
# the original assert_unauthenticated/assert_unauthorized wrapped the request
# in `lambda { ... }.should raise_error(...)`. ApplicationController now
# rescues both (see rescue_from in app/controllers/application_controller.rb)
# and turns them into an HTTP response before they ever reach the spec, so
# these assert the *response* instead of a raised exception. The intent is
# unchanged: a guest can't reach the action (redirected to the login page);
# an authenticated-but-not-permitted user gets rejected (401).
module ExceptionsHelper
  def assert_unauthenticated(&block)
    block.call
    expect(response).to redirect_to(login_path)
  end

  def assert_unauthorized(&block)
    block.call
    expect(response).to have_http_status(:unauthorized)
  end
end
