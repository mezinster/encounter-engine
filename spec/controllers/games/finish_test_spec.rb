# -*- encoding : utf-8 -*-
require "rails_helper"

# Blocker fix: GamesController#finish_test wipes every GamePassing and Log
# for the game (i.e. the progress of every team in a live test) with no
# author check -- only find_game ran before it. See
# app/controllers/games_controller.rb's before_action :ensure_author list.
RSpec.describe GamesController, "#finish_test", type: :controller do
  describe "when the game author finishes the test" do
    before :each do
      @user = create_user
      @game = create_game :author => @user, :is_testing => true, :test_date => "2099-02-02 00:00"
      @game_passing = create_game_passing :game => @game, :level => create_level(:game => @game)
    end

    it "wipes the game's passings and redirects" do
      perform_request(:as_user => @user)
      expect(GamePassing.of_game(@game)).to be_empty
      expect(response).to redirect_to(@game)
    end
  end

  # The second half of the end-game-during-test trap (see end_game_spec):
  # even with end_game now refusing test-mode games, a stray
  # author_finished_at must not survive the test teardown, which already
  # deletes every other trace of the run (passings, logs).
  describe "when the author finishes a test of a game carrying an author finish" do
    before :each do
      @user = create_user
      @game = create_game :author => @user, :is_testing => true, :test_date => "2099-02-02 00:00",
                          :author_finished_at => Time.now
    end

    it "clears the author finish along with the rest of the test's traces" do
      perform_request(:as_user => @user)
      expect(@game.reload.author_finished?).to be false
    end
  end

  describe "when any other logged-in user attempts to finish the test" do
    before :each do
      @user = create_user
      @game = create_game :is_testing => true, :test_date => "2099-02-02 00:00"
      @game_passing = create_game_passing :game => @game, :level => create_level(:game => @game)
    end

    it "raises Unauthorized exception and leaves the passings intact" do
      assert_unauthorized { perform_request(:as_user => @user) }
      expect(GamePassing.of_game(@game)).not_to be_empty
    end
  end

  describe "when a guest attempts to finish the test" do
    before :each do
      @game = create_game :is_testing => true, :test_date => "2099-02-02 00:00"
      @game_passing = create_game_passing :game => @game, :level => create_level(:game => @game)
    end

    it "raises Unauthenticated exception and leaves the passings intact" do
      assert_unauthenticated { perform_request }
      expect(GamePassing.of_game(@game)).not_to be_empty
    end
  end

  # Reported from production 2026-08-13: an author could not leave test mode at
  # all, and the game was stuck in testing with no way out through any form.
  #
  # start_test parks the real start date in test_date and sets starts_at to
  # now; finish_test swaps them back AND clears author_finished_at, which is
  # the only thing suppressing game_starts_in_the_future. So once the parked
  # date is in the past the save is refused -- and the parked date sits still
  # while the clock moves, which makes this MORE likely the longer the test
  # runs. Testing close to a game's scheduled start is exactly when an author
  # tests, and test_date is in no permitted-params list, so nothing the author
  # could type would fix it.
  #
  # Every other example in this file parks "2099-02-02", so the whole suite
  # only ever exercised the case that works.
  describe "when the parked start date has passed during the test" do
    before :each do
      @user = create_user
      @game = create_game :author => @user, :is_testing => true,
                          :test_date => 1.day.ago
    end

    it "still leaves test mode" do
      perform_request(:as_user => @user)

      expect(@game.reload.is_testing?).to be false
      expect(@game.is_draft).to be true
    end

    it "redirects to the game rather than bouncing back with an alert" do
      perform_request(:as_user => @user)

      expect(response).to redirect_to(@game)
      expect(flash[:alert]).to be_nil
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :finish_test, params: { id: @game.id }
    response
  end
end
