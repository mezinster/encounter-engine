# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe InvitationsController, "#new", type: :controller do
  describe "security filters" do
    describe "captain attempts to invites a new member" do
      before :each do
        @captain = create_user
        @team = create_team :captain => @captain
        @response = perform_request :as_user => @captain
      end

      it "responds successfully" do
        expect(@response).to have_http_status(:success)
      end
    end

    describe "a regular team member attepmts to invite a new member" do
      before :each do
        @captain = create_user
        @member = create_user
        @team = create_team :captain => @captain, :members => [@member]
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request :as_user => @member }
      end
    end

    describe "a guest attempts to create an invitation" do
      it "raises Unauthenticated exception" do
        assert_unauthenticated { perform_request }
      end
    end
  end

  describe "when it receives blank string as 'for_user' parameter" do
    before :each do
      @captain = create_user
      @team = create_team :captain => @captain
      @response = perform_request :as_user => @captain
      @params = { :invitation => { :recepient_nickname => "" } }
    end

    it "does not raise error" do
      expect do
        perform_request( { :as_user => @captain }, @params)
      end.not_to raise_error
    end
  end

  describe "when it receives a string with email as 'for_user' parameter" do
    before :each do
      @captain = create_user
      @team = create_team :captain => @captain
      @response = perform_request :as_user => @captain
      @params = { :invitation => { :recepient_nickname => "SomeUser" } }
    end

    it "does not raise error" do
      expect do
        perform_request( { :as_user => @captain }, @params)
      end.not_to raise_error
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    get :new, params: params
    response
  end
end
