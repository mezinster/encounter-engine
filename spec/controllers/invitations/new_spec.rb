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

  # These two used to assert `should_not raise_error`, which -- now that a
  # denial redirects/401s instead of raising -- would pass whether the
  # captain was let through or rejected, and #new never even reads these
  # params (see InvitationsController#new), so the assertion proved
  # nothing about "for_user" handling either. Asserting the real response
  # status confirms the captain still reaches the form regardless of what
  # (unused, on this action) recepient_nickname value happens to be present.
  describe "when it receives blank string as 'for_user' parameter" do
    before :each do
      @captain = create_user
      @team = create_team :captain => @captain
      @params = { :invitation => { :recepient_nickname => "" } }
    end

    it "still responds successfully" do
      perform_request({ :as_user => @captain }, @params)
      expect(response).to have_http_status(:success)
    end
  end

  describe "when it receives a string with email as 'for_user' parameter" do
    before :each do
      @captain = create_user
      @team = create_team :captain => @captain
      @params = { :invitation => { :recepient_nickname => "SomeUser" } }
    end

    it "still responds successfully" do
      perform_request({ :as_user => @captain }, @params)
      expect(response).to have_http_status(:success)
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    get :new, params: params
    response
  end
end
