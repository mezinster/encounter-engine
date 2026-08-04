# -*- encoding : utf-8 -*-
class SessionsController < ApplicationController
  def new; end

  def create
    # login_param = :email in the Merb app (merb/merb-auth/strategies.rb:9):
    # users authenticate by e-mail address, not nickname.
    user = User.find_by(email: params[:email])

    if user&.authenticate(params[:password])
      # merb-auth abandoned (cleared) the session on login
      # (vendor/merb-auth/merb-auth-slice-password/app/controllers/sessions.rb:4,
      # merb-auth-core/lib/merb-auth-core/authentication.rb:113-116). Without
      # this, session[:user_id] merges into whatever session the request
      # arrived with, including a session fixated by an attacker before the
      # victim logs in -- and since the session cookie also carries the CSRF
      # token, protect_from_forgery does not catch this. reset_session issues
      # a fresh session id and empties the session before we write to it.
      reset_session
      session[:user_id] = user.id
      redirect_to dashboard_path
    else
      flash.now[:error] = t("sessions.invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    # reset_session (not session.delete(:user_id)) to match merb-auth's
    # session.abandon!, which cleared the whole session, not just the login
    # key. Deleting only :user_id is harmless today because nothing else
    # writes to the session, but it would leak session data across a logout
    # the moment something else -- e.g. a return_to path or the locale --
    # starts using the session too.
    reset_session
    redirect_to root_path
  end
end
