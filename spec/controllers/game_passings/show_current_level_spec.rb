# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe GamePassingsController, "#show_current_level", type: :controller do
  before :each do
    now = Time.now
    Time.stub(:now => now - 1)
    @started_game = create_game :starts_at => now
    @first_level = create_level :game => @started_game
    create_level :game => @started_game
    @started_game.reload
    Time.stub(:now => now + 1)

    @team_member = create_user
    @team = create_team :captain => @team_member
  end

  describe "when guest tries to enter game passing" do
    it "raises Unauthenticated exception" do
      assert_unauthenticated { perform_request :game => @started_game }
    end
  end

  describe "when not a team member tries to enter game passing" do
    it "raises Unauthorized exception" do
      lonely_user = create_user
      assert_unauthorized { perform_request :as_user => lonely_user, :game => @started_game }
    end
  end

  describe "when a team member tries to enter game which is not started yet" do
    before :each do
      @not_started_game = create_game :starts_at => Time.now + 1000
    end

    it "raises Unauthorized exception" do
      assert_unauthorized { perform_request :as_user => @team_member, :game => @not_started_game }
    end
  end

  describe "when game author tries to enter game passing" do
    before :each do
      @author = create_user
      create_team :captain => @author
      @started_game.update_attribute(:author, @author)
    end

    it "raises Unauthorized exception" do
      assert_unauthorized { perform_request :as_user => @author, :game => @started_game }
    end
  end

  describe "when a team member enters game passing" do
    before :each do
      create_game_entry :game => @started_game, :team => @team
    end

    it "responds successfully" do
      @response = perform_request :as_user => @team_member, :game => @started_game
      expect(@response).to have_http_status(:success)
    end

    it "creates and assigns game passing" do
      expect do
        @response = perform_request :as_user => @team_member, :game => @started_game
      end.to change(GamePassing, :count).by(1)
    end

    it "does not create game passing for any subsequent call" do
      @response = perform_request :as_user => @team_member, :game => @started_game
      initial_game_passing = assigns(:game_passing)

      expect do
        @response = perform_request :as_user => @team_member, :game => @started_game
      end.not_to change(GamePassing, :count)

      assigns(:game_passing).id.should == initial_game_passing.id
    end

    it "assigns correct data to game passing attribute" do
      @response = perform_request :as_user => @team_member, :game => @started_game

      game_passing = assigns(:game_passing)
      game_passing.game.id.should == @started_game.id
      game_passing.team.id.should == @team.id
      game_passing.current_level.id.should == @first_level.id
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    get :show_current_level, params: { game_id: opts[:game].id }
    response
  end
end
