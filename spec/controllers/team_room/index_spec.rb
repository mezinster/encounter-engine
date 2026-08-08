# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe TeamRoomController, "#index", type: :controller do
  describe "when guest enters the team room" do
    it "raises Unauthenticated exception" do
      assert_unauthenticated { perform_request }
    end
  end

  describe "when not a team member enters the team room" do
    it "raises Unauthorized exception" do
      user = create_user
      assert_unauthorized { perform_request :as_user => user }
    end
  end

  describe "when a team member or captain enters the dashboard" do
    before :each do
      user = create_user
      create_team :captain => user
      @response = perform_request :as_user => user
    end

    it "should respond successfully" do
      expect(@response).to have_http_status(:success)
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    get :index
    response
  end
end
