# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe GamesController, "#create", type: :controller do
  describe "security filters" do
    describe "registered user attempts create a game" do
      before :each do
        @user = create_user
      end

      describe "data is valid" do
        before :each do
          @params = { :game => { :name => "Blablabla#{rand(10000)}", :description => "More blablablablabla",
            :max_team_number => 10 } }
        end

        it "crates a game" do
          expect do
            perform_request({ :as_user => @user }, @params)
          end.to change(Game, :count).by(1)
        end

        it "assigns current user as an author of the game" do
          @response = perform_request({ :as_user => @user }, @params)
          Game.last.author.id.should == @user.id
        end

        it "redirects to game profile"
      end

      describe "data is invalid" do
        before :each do
          @response = perform_request({ :as_user => @user })
        end

        it "renders a form again"
      end
    end

    describe "a guest attempts to create an invitation" do
      it "raises Unauthenticated exception" do
        assert_unauthenticated { perform_request }
      end
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :create, params: params
    response
  end
end
