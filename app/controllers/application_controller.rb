# -*- encoding : utf-8 -*-
class ApplicationController < ActionController::Base
  include Authentication
  include LocaleSelection

  rescue_from Authentication::Unauthenticated, with: :deny_unauthenticated
  rescue_from Authentication::Unauthorized,    with: :deny_unauthorized

  helper_method :current_user, :logged_in?

  private

  def deny_unauthenticated
    respond_to do |format|
      format.html { redirect_to login_path, alert: t("errors.unauthenticated") }
    end
  end

  def deny_unauthorized(exception)
    render plain: exception.message.presence || t("errors.unauthorized"),
           status: :unauthorized
  end
end
