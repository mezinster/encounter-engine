# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe LevelsController, "#move_up", type: :controller do
  before :each do
    @level = create_level
  end

  describe "security filters" do
    describe "when any other user attempts to move a level up" do
      before :each do
        @user = create_user
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request(:as_user => @user) }
      end
    end

    describe "when a guest attempts to move a level" do
      # See the equivalent note in levels/move_down_spec.rb: no separate
      # authentication filter here, ensure_author covers guests too.
      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request }
      end
    end
  end

  describe "when authour moves level up correctly" do
    before :each do
      @author = create_user
      @game = create_game :author => @author
      create_level :game => @game
      @level = create_level :game => @game
      create_level :game => @game
      @initial_level_position = @level.position
    end

    it "actually moves level up" do
      expect do
        perform_request :as_user => @author
      end.to change { @level.reload.position }.by(-1)
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    get :move_up, params: params.merge(:id => @level.id, :game_id => @level.game.id)
    response
  end
end
