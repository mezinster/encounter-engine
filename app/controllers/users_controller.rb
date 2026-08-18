# -*- encoding : utf-8 -*-
class UsersController < ApplicationController
  include RequestThrottling

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
    # Honeypot: see the field's comment in app/views/users/new.html.erb. Read
    # straight off params -- signup_params permits only nickname and email, so
    # this would be stripped before it could ever be checked.
    #
    # Answers with an ordinary redirect rather than an error, so an operator
    # watching responses cannot find the trap by diffing them. Nothing is
    # created and nothing is mailed. Checked BEFORE the throttle, so a bot's
    # flood does not consume the per-IP budget that real people share.
    if params[:website].present?
      redirect_to login_path, :notice => t("users.create.check_your_mail")
      return
    end

    # Before anything is built or saved: a refused request must cost this
    # server as little as it costs the client.
    unless throttle!("signup")
      @user = User.new(signup_params)
      flash.now[:alert] = t("errors.too_many_requests")
      render :new, status: :too_many_requests
      return
    end

    @user = User.new(signup_params)

    # Registration no longer collects a password -- the server generates the
    # first one (product decision, 2026-08-08: see the third authorised
    # feature-file exception in CLAUDE.md). Generated here, not on the model,
    # so a console- or fixture-created User (create_user, User.create! in
    # specs, etc.) is unaffected and still takes whatever password it's
    # given -- a model-level default would silently apply there too. Set on
    # both password and password_confirmation: User validates
    # password_confirmation's presence whenever password_required? is true
    # (both hash columns are blank on a new record), so leaving it unset
    # would make every signup invalid.
    generated_password = SecureRandom.alphanumeric(12)
    @user.password = generated_password
    @user.password_confirmation = generated_password

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

    # A new password requires proof of the current one. Without this, momentary
    # access to a logged-in browser was a permanent account takeover: the
    # profile form re-hashes on any save where password is present, and this
    # app has no recovery flow, so the victim could not get back in at all.
    if params.dig(:user, :password).present? &&
       !@user.authenticate(params.dig(:user, :current_password).to_s)
      @user.errors.add(:base, t("users.edit.current_password_wrong"))
      render :edit, status: :unprocessable_entity
      return
    end

    if @user.update(profile_params)
      # The profile is where a lasting choice of language is made, so saving it
      # discards whatever ?locale= left in the session -- otherwise a preview
      # taken earlier in the same session would outrank the preference just
      # saved, and the form would look broken. See LocaleSelection#set_locale.
      session.delete(:locale)

      if params.dig(:user, :password).present?
        reset_session
        session[:user_id] = @user.id
        session[:session_token] = @user.reload.session_token
      end
      redirect_to users_path
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  # reset_session before writing :user_id, matching SessionsController#create
  # (sessions_controller.rb:20). Registration is the same anonymous ->
  # authenticated transition, and the session cookie also carries the CSRF
  # token, so the two entry points must look identical.
  def authenticate_user
    reset_session
    session[:user_id] = @user.id
    session[:session_token] = @user.session_token
  end

  # app/views/users/new.html.erb (signup form) submits nickname, email only --
  # :password/:password_confirmation are deliberately NOT permitted here. The
  # server generates the first password in #create; permitting either of
  # these would let a signup request choose its own account's credential.
  def signup_params
    params.fetch(:user, ActionController::Parameters.new)
          .permit(:nickname, :email)
  end

  # app/views/users/edit.html.erb (profile form) submits nickname,
  # date_of_birth, instagram, telegram_id, on_telegram,
  # on_whatsapp, on_viber, on_signal, on_max, phone_number, locale, timezone,
  # password, password_confirmation. No email, and no team_id or any field
  # that could let a user attach themself to a different team through this
  # form.
  #
  # :locale is not restricted to I18n.available_locales here -- the <select>
  # only ever offers those values (app/views/users/edit.html.erb), and
  # LocaleSelection#current_user_locale re-checks membership on every read,
  # so a value smuggled in by a raw PATCH is stored but never trusted.
  def profile_params
    params.fetch(:user, ActionController::Parameters.new)
          .permit(:nickname, :date_of_birth,
                   :instagram, :telegram_id,
                   :on_telegram, :on_whatsapp, :on_viber, :on_signal, :on_max,
                   :phone_number, :locale, :timezone, :password, :password_confirmation)
  end

  # Merb original: app/controllers/users.rb#send_welcome_letter_to, which
  # passed user.email and user.password to NotificationMailer#welcome_letter.
  # user.password is the plaintext virtual attribute set earlier in #create
  # (before_save hashes it into password_digest -- see User#encrypt_password),
  # so it's still readable here.
  def send_welcome_letter_to(user)
    NotificationMailer.welcome_letter(user, user.password).deliver_now
  end
end
