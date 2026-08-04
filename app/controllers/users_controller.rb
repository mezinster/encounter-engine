# -*- encoding : utf-8 -*-
class UsersController < ApplicationController
  # SECURITY FIX (see .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-S-report.md):
  # The Merb original (app/controllers/users.rb) had no `before` filters at
  # all -- not even ensure_authenticated on #update, which loaded @user by
  # params[:id] rather than from current_user. That meant ANY request,
  # including an anonymous one, could take over any account by PATCHing
  # /users/:id with a new password -- User#before_save re-hashes whenever a
  # password is present, so the victim's account would immediately
  # authenticate with the attacker's password. This was preserved unchanged
  # through the mechanical port (see task-8b-report.md) and is fixed here:
  # #update now requires a signed-in user and always operates on
  # current_user, never on an id taken from the request. #edit gets the same
  # require_authentication! for consistency -- it already scoped @user to
  # current_user, so it was never exploitable, but a guest hitting it hit a
  # 500 instead of a clean login redirect (the real cause is unrelated to
  # @user: app/views/users/edit.html.erb calls error_messages_for, an
  # unported Merb helper -- one of 11 views repo-wide still doing that.
  # That belongs to the view-porting task, not this one).
  before_action :require_authentication!, only: [:edit, :update]

  def show
    @user = User.find(params[:id])
  end

  def index
  end

  def new
    @user = User.new(signup_params)
  end

  def create
    @user = User.new(signup_params)

    if @user.save
      authenticate_user
      send_welcome_letter_to(@user)
      redirect_to dashboard_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @user = current_user
  end

  def update
    @user = current_user

    if @user.update(profile_params)
      redirect_to users_path
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def authenticate_user
    session[:user_id] = @user.id
  end

  # app/views/users/new.html.erb (signup form) submits nickname, email,
  # password, password_confirmation.
  def signup_params
    params.fetch(:user, ActionController::Parameters.new)
          .permit(:nickname, :email, :password, :password_confirmation)
  end

  # app/views/users/edit.html.erb (profile form) submits nickname,
  # date_of_birth, icq_number, jabber_id, phone_number, password,
  # password_confirmation. No email, and no team_id or any field that could
  # let a user attach themself to a different team through this form.
  def profile_params
    params.fetch(:user, ActionController::Parameters.new)
          .permit(:nickname, :date_of_birth, :icq_number, :jabber_id,
                   :phone_number, :password, :password_confirmation)
  end

  # TODO(Task 10): app/mailers/notification_mailer.rb is still the pre-port
  # Merb::MailController and cannot be referenced from Rails yet (referencing
  # the constant raises NameError: uninitialized constant Merb -- same
  # situation as the four TODO(Task 10) sites in
  # app/controllers/invitations_controller.rb). The Merb original sent a
  # "welcome_letter" email here containing the user's plaintext password;
  # restore that call once Task 10 ports NotificationMailer to ActionMailer.
  def send_welcome_letter_to(user)
  end
end
