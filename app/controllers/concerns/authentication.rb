# -*- encoding : utf-8 -*-
module Authentication
  extend ActiveSupport::Concern

  class Unauthenticated < StandardError; end
  class Unauthorized < StandardError; end

  private

  def current_user
    return @current_user if defined?(@current_user)

    user = session[:user_id] && User.find_by(id: session[:user_id])
    # The token binds this cookie to the credential it was issued under. A
    # cookie minted before a password change no longer resolves, which is what
    # evicts a stolen session -- reset_session cannot, because it only rotates
    # the browser making the request.
    @current_user = if user && user.session_token.present? &&
                       ActiveSupport::SecurityUtils.secure_compare(
                         session[:session_token].to_s, user.session_token)
                      user
                    end
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
