# -*- encoding : utf-8 -*-
module Authentication
  extend ActiveSupport::Concern

  class Unauthenticated < StandardError; end
  class Unauthorized < StandardError; end

  private

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:user_id] && User.find_by(id: session[:user_id])
  end

  def logged_in?
    !!current_user
  end

  # Must run before any filter that touches current_user. In the Merb app the
  # order was inverted, so a guest hitting a play URL got a 500 rather than a
  # login prompt.
  def require_authentication!
    raise Unauthenticated unless logged_in?
  end
end
