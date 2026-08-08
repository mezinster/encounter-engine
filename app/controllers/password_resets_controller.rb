# -*- encoding : utf-8 -*-
class PasswordResetsController < ApplicationController
  def new
  end

  # Responds identically whether or not the address is registered. The login
  # form already refuses to distinguish "no such e-mail" from "wrong password"
  # (sessions_controller.rb:24) and this must not undo that.
  def create
    user = User.find_by(email: params[:email].to_s.strip)

    if user
      token = user.issue_reset_password_token!
      NotificationMailer.password_reset(user, token).deliver_now
    end

    redirect_to login_path, notice: t("password_resets.create.sent")
  end

  def edit
    @token = params[:token].to_s
    redirect_to new_password_reset_path, alert: t("password_resets.invalid") unless User.find_by_reset_token(@token)
  end

  def update
    @token = params[:token].to_s
    user = User.find_by_reset_token(@token)

    unless user
      redirect_to new_password_reset_path, alert: t("password_resets.invalid")
      return
    end

    if user.update(password: params.dig(:user, :password),
                   password_confirmation: params.dig(:user, :password_confirmation))
      # Single use, and the password change has already rotated session_token
      # (see AddSessionTokenToUsers), so every other session is now dead.
      user.clear_reset_password_token!
      reset_session
      redirect_to login_path, notice: t("password_resets.update.done")
    else
      @user = user
      render :edit, status: :unprocessable_entity
    end
  end
end
