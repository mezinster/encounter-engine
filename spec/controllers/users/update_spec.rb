# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe UsersController, "#update", type: :controller do
  before :each do
    @user = create_user
  end

  describe "with valid data" do
    it "updates the user's profile fields" do
      perform_request(:as_user => @user, :params => { user: { nickname: @user.nickname, instagram: "player" } })
      expect(@user.reload.instagram).to eq("player")
    end

    it "redirects to the users list" do
      perform_request(:as_user => @user, :params => { user: { nickname: @user.nickname } })
      expect(response).to redirect_to(users_path)
    end
  end

  describe "with invalid data" do
    it "does not update the user" do
      perform_request(:as_user => @user, :params => { user: { nickname: "" } })
      expect(@user.reload.nickname).not_to eq("")
    end

    it "re-renders the edit form" do
      perform_request(:as_user => @user, :params => { user: { nickname: "" } })
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "strong parameters" do
    # profile_params permits nickname/date_of_birth/
    # instagram/telegram_id/on_telegram/on_whatsapp/on_viber/on_signal/
    # on_max/phone_number/locale/timezone/password/password_confirmation
    # (see app/views/users/edit.html.erb) -- editing a profile must not let a
    # request move the account to a different team.
    it "ignores an attempted team_id" do
      team = create_team
      perform_request(:as_user => @user,
                       :params => { user: { nickname: @user.nickname, team_id: team.id } })

      expect(@user.reload.team_id).to be_nil
    end

    # A missing `permit` entry silently drops the value rather than raising,
    # so this has to be an end-to-end PATCH-and-reload assertion, not just a
    # check that the params list mentions the key.
    it "persists an attempted Instagram handle" do
      perform_request(:as_user => @user,
                       :params => { user: { nickname: @user.nickname, instagram: "newhandle" } })

      expect(@user.reload.instagram).to eq("newhandle")
    end

    # Booleans arrive from an HTML checkbox as the strings "1"/"0", not a
    # real true/false -- a second, independent way for this to quietly fail
    # even once the key is permitted.
    it "persists an attempted on_signal flag sent as the string \"1\"" do
      perform_request(:as_user => @user,
                       :params => { user: { nickname: @user.nickname, on_signal: "1" } })

      expect(@user.reload.on_signal).to eq(true)
    end
  end

  # SECURITY REGRESSION SPECS (see
  # .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-S-report.md):
  # #update used to load @user from params[:id] with no authentication check
  # at all, so an anonymous request carrying a victim's id plus a new
  # user[password]/user[password_confirmation] took over that account --
  # User#encrypt_password re-hashes on save whenever a password is present.
  # #update now requires a signed-in user and always operates on
  # current_user, ignoring whatever id is in the request.
  describe "security" do
    it "raises Unauthenticated exception for a guest" do
      assert_unauthenticated do
        perform_request(:id => @user.id,
                         :params => { user: { password: "pwned", password_confirmation: "pwned" } })
      end
    end

    # The core exploit: an unauthenticated PATCH carrying another user's id
    # plus a new password must not be able to take over that account.
    it "does not let an anonymous request change another user's password" do
      perform_request(:id => @user.id,
                       :params => { user: { password: "pwned", password_confirmation: "pwned" } })

      expect(@user.reload.authenticate("pwned")).to be_falsey
    end

    it "updates the signed-in user's own profile even when a different id is posted" do
      attacker = create_user
      victim_original_nickname = @user.nickname

      perform_request(:as_user => attacker, :id => @user.id,
                       :params => { user: { nickname: "attacker-controlled" } })

      expect(@user.reload.nickname).to eq(victim_original_nickname)
      expect(attacker.reload.nickname).to eq("attacker-controlled")
    end

    it "does not let a logged-in user change another user's password by posting their id" do
      attacker = create_user

      perform_request(:as_user => attacker, :id => @user.id,
                       :params => { user: { password: "pwned", password_confirmation: "pwned" } })

      expect(@user.reload.authenticate("pwned")).to be_falsey
    end
  end

  def perform_request(opts = {})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    patch :update, params: (opts[:params] || {}).merge(id: opts[:id] || @user.id)
    response
  end
end
