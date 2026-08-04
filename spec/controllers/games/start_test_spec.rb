# -*- encoding : utf-8 -*-
require "rails_helper"

# Blocker fix: GamesController#start_test force-starts a scheduled game
# (nulling its registration_deadline) with no author check -- only
# find_game ran before it. See app/controllers/games_controller.rb's
# before_action :ensure_author list.
RSpec.describe GamesController, "#start_test", type: :controller do
  describe "when the game author starts the test" do
    before :each do
      @user = create_user
      @game = create_game :author => @user
    end

    it "puts the game into testing mode and redirects" do
      perform_request(:as_user => @user)
      @game.reload
      expect(@game.is_testing?).to be true
      expect(response).to redirect_to(@game)
    end
  end

  describe "when any other logged-in user attempts to start the test" do
    before :each do
      @user = create_user
      @game = create_game
    end

    it "raises Unauthorized exception and leaves the game untouched" do
      assert_unauthorized { perform_request(:as_user => @user) }
      expect(@game.reload.is_testing?).to be false
    end
  end

  describe "when a guest attempts to start the test" do
    before :each do
      @game = create_game
    end

    it "raises Unauthenticated exception and leaves the game untouched" do
      assert_unauthenticated { perform_request }
      expect(@game.reload.is_testing?).to be false
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    get :start_test, params: { id: @game.id }
    response
  end
end
