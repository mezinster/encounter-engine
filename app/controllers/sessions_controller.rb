# -*- encoding : utf-8 -*-
class SessionsController < ApplicationController
  def new; end

  def create
    # login_param = :email in the Merb app (merb/merb-auth/strategies.rb:9):
    # users authenticate by e-mail address, not nickname.
    user = User.find_by(email: params[:email])

    if user&.authenticate(params[:password])
      session[:user_id] = user.id
      redirect_to dashboard_path
    else
      flash.now[:error] = t("sessions.invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path
  end
end
