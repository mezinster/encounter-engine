# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe LevelsController, "#new", type: :controller do
  describe "security filters" do
    describe "when the game author attempts to create a new level" do
      before :each do
        @author = create_user
        @game = create_game :author => @author
      end

      it "responds successfully" do
        perform_request(:as_user => @author)
        expect(response).to have_http_status(:success)
      end
    end

    describe "when any other user attempts to create a new level" do
      before :each do
        @user = create_user
        @game = create_game
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request(:as_user => @user) }
      end
    end

    describe "when a guest attempts to create a new level" do
      before :each do
        @game = create_game :is_draft => false
      end

      # See the equivalent note in levels/move_down_spec.rb.
      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request }
      end
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    get :new, params: params.merge(:game_id => @game.id)
    response
  end
end
