# -*- encoding : utf-8 -*-
require "rails_helper"

# Blocker fix: GamesController#end_game ends a live game (and ends every
# team's GamePassing) with no author check -- only find_game ran before it.
# See app/controllers/games_controller.rb's before_action :ensure_author
# list.
RSpec.describe GamesController, "#end_game", type: :controller do
  describe "when the game author ends the game" do
    before :each do
      @user = create_user
      @game = create_game :author => @user
    end

    it "finishes the game and redirects" do
      perform_request(:as_user => @user)
      expect(@game.reload.author_finished?).to be true
      expect(response).to redirect_to(dashboard_path)
    end
  end

  # During a test run the game is "started", so the dashboard offered the
  # end-game link right next to the finish-test flow -- and clicking it set
  # author_finished_at permanently. finish_test then cleaned up passings and
  # logs but not that timestamp, leaving a scheduled game that reported itself
  # "Завершена" the moment it left draft (Game#status checks draft first, so
  # the damage stayed masked until publication). Observed in production,
  # game.mezin.eu, 2026-08-08 02:19.
  describe "when the game author attempts to end a game that is in test mode" do
    before :each do
      @user = create_user
      @game = create_game :author => @user, :is_testing => true, :test_date => "2099-02-02 00:00"
    end

    it "refuses, leaves the game unfinished and redirects back to the game" do
      perform_request(:as_user => @user)
      expect(@game.reload.author_finished?).to be false
      expect(response).to redirect_to(game_path(@game))
      expect(flash[:alert]).to eq(I18n.t("games.not_endable_in_test"))
    end
  end

  describe "when any other logged-in user attempts to end the game" do
    before :each do
      @user = create_user
      @game = create_game
    end

    it "raises Unauthorized exception and leaves the game running" do
      assert_unauthorized { perform_request(:as_user => @user) }
      expect(@game.reload.author_finished?).to be false
    end
  end

  describe "when a guest attempts to end the game" do
    before :each do
      @game = create_game
    end

    it "raises Unauthenticated exception and leaves the game running" do
      assert_unauthenticated { perform_request }
      expect(@game.reload.author_finished?).to be false
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    get :end_game, params: { id: @game.id }
    response
  end
end
