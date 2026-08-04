# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe UsersController, "#update", type: :controller do
  before :each do
    @user = create_user
  end

  describe "with valid data" do
    it "updates the user's profile fields" do
      perform_request(:as_user => @user, :params => { user: { nickname: @user.nickname, icq_number: "123456" } })
      expect(@user.reload.icq_number).to eq("123456")
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
    # profile_params permits nickname/date_of_birth/icq_number/jabber_id/
    # phone_number/password/password_confirmation (see
    # app/views/users/edit.html.erb) -- editing a profile must not let a
    # request move the account to a different team.
    it "ignores an attempted team_id" do
      team = create_team
      perform_request(:as_user => @user,
                       :params => { user: { nickname: @user.nickname, team_id: team.id } })

      expect(@user.reload.team_id).to be_nil
    end
  end

  def perform_request(opts = {})
    session[:user_id] = opts[:as_user]&.id
    patch :update, params: (opts[:params] || {}).merge(id: @user.id)
    response
  end
end
