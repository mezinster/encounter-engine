# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe TeamsController, "#new", type: :controller do
  describe "regular case, fresh user attempts to create a team" do
    before :each do
      User.delete_all
      user = create_user
      @response = perform_request :as_user => user
    end

    it "responds successfully" do
      expect(@response).to have_http_status(:success)
    end
  end

  describe "a guest attempts to create a team" do
    it "raises Unauthenticated exception" do
      assert_unauthenticated { perform_request }
    end
  end

  describe "a member/captain of some team attempts to create another team" do
    before :each do
      @user = create_user
      @team = create_team :captain => @user
    end

    it "raises Unauthorized exception with the right message" do
      perform_request :as_user => @user
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq("Вы уже являетесь членом команды")
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    get :new
    response
  end
end
