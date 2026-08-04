# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe GamesController, "#new", type: :controller do
  describe "security filters" do
    describe "registered user attempts to create a game" do
      before :each do
        # The Merb original stubbed session.user to @captain here, which was
        # never assigned (nil) -- but session.authenticated? was stubbed
        # from opts.key?(:as_user), true even for a nil value, so the old
        # test exercised an "authenticated with no real user" edge case that
        # session[:user_id]-based auth has no equivalent for. @user (the
        # user actually created above) is what this block's own title says
        # was intended.
        @user = create_user
        @response = perform_request :as_user => @user
      end

      it "responds successfully" do
        expect(@response).to have_http_status(:success)
      end
    end

    describe "a guest attempts to create game" do
      it "raises Unauthenticated exception" do
        assert_unauthenticated { perform_request }
      end
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    get :new, params: params
    response
  end
end
