# -*- encoding : utf-8 -*-
class UsersController < ApplicationController
  # The Merb original (app/controllers/users.rb) had no `before` filters at
  # all -- not even ensure_authenticated on #update, which loads @user by
  # params[:id] rather than from current_user. That means any logged-in
  # user (arguably any guest, since #update has no auth check either) could
  # already update any other user's profile by posting a different :id in
  # the Merb app. This port preserves that behaviour unchanged rather than
  # silently hardening it -- see task-8b-report.md for the full writeup;
  # it's flagged there as a concern for a reviewer to weigh in on, not
  # something this mechanical-port task should fix on its own judgment.
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
    @user = User.find(params[:id])

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
