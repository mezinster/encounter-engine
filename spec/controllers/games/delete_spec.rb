# -*- encoding : utf-8 -*-
require "rails_helper"

# Blocker fix: GamesController#delete destroys the game outright and had no
# author check at all -- only find_game ran before it, so any logged-in
# user could GET /games/:id/delete against any game id and delete it. See
# app/controllers/games_controller.rb's before_action :ensure_author list.
RSpec.describe GamesController, "#delete", type: :controller do
  describe "when the game author deletes their game" do
    before :each do
      @user = create_user
      @game = create_game :author => @user
    end

    it "destroys the game and redirects" do
      perform_request(:as_user => @user)
      expect(Game.exists?(@game.id)).to be false
      expect(response).to redirect_to(dashboard_path)
    end
  end

  describe "when any other logged-in user attempts to delete the game" do
    before :each do
      @user = create_user
      @game = create_game
    end

    it "raises Unauthorized exception and leaves the game intact" do
      assert_unauthorized { perform_request(:as_user => @user) }
      expect(Game.exists?(@game.id)).to be true
    end
  end

  describe "when a guest attempts to delete the game" do
    before :each do
      @game = create_game
    end

    it "raises Unauthenticated exception and leaves the game intact" do
      assert_unauthenticated { perform_request }
      expect(Game.exists?(@game.id)).to be true
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    get :delete, params: { id: @game.id }
    response
  end
end
