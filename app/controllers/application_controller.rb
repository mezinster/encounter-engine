# -*- encoding : utf-8 -*-
class ApplicationController < ActionController::Base
  include Authentication
  include LocaleSelection

  rescue_from Authentication::Unauthenticated, with: :deny_unauthenticated
  rescue_from Authentication::Unauthorized,    with: :deny_unauthorized

  helper_method :current_user, :logged_in?

  # Several views read the ivar directly (e.g.
  # app/views/shared/_countdown.html.erb: `@current_user.author_of?(@game)`)
  # rather than calling the `current_user` helper. `current_user` (see
  # Authentication#current_user) memoizes into @current_user, but nothing
  # ever guaranteed it ran before an action -- it only worked by accident,
  # because LocaleSelection#set_locale (app/controllers/concerns/
  # locale_selection.rb) calls current_user_locale, which calls
  # current_user, as a side effect of picking the locale. Make the
  # dependency explicit instead of relying on that side effect. Added
  # *after* `include LocaleSelection` so set_locale still runs first,
  # unchanged -- this callback is idempotent (current_user memoizes) so its
  # position relative to set_locale doesn't matter functionally, but it must
  # not be reordered ahead of it per this task's constraints.
  before_action :set_current_user

  private

  def set_current_user
    current_user
  end

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
