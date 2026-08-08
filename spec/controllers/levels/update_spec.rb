# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe LevelsController, "#update", type: :controller do
  describe "security filters" do
    describe "when any other user attempts to update a level" do
      before :each do
        @user = create_user
        @level = create_level
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request(:as_user => @user) }
      end
    end

    describe "when a guest attempts to update a level" do
      before :each do
        @level = create_level
      end

      # See the equivalent note in levels/move_down_spec.rb.
      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request }
      end
    end
  end

  describe "when author attempts to update level after game is already started" do
    before :each do
      @author = create_user
      tomorrow = DateTime.now + 1
      @game = create_game :author => @author, :starts_at => tomorrow
      @level = create_level :game => @game
      day_after_tomorrow = tomorrow + 1
      Time.stub(:now => day_after_tomorrow)
    end

    it "raises Unauthorized exception" do
      assert_unauthorized { perform_request(:as_user => @author) }
    end
  end

  describe "when authour updates level correctly" do
    before :each do
      @author = create_user
      @game = create_game :author => @author
      create_level :game => @game
      @level = create_level :game => @game
      create_level :game => @game
      @initial_level_position = @level.position
      perform_request({ :as_user => @author }, { :level => { :text => "Some other text" } })
    end

    it "does not change position of level" do
      @level.reload
      @level.position.should == @initial_level_position
    end

    # A text-only update never touches position (acts_as_list scope: :game),
    # so the assertion above holds whether the update actually ran or was
    # blocked before reaching the controller -- it cannot detect a broken
    # #update on its own. This asserts the attribute the request itself
    # changed, so the block can no longer pass vacuously.
    it "updates the level's text" do
      @level.reload
      @level.text.should == "Some other text"
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    patch :update, params: params.merge(:id => @level.id, :game_id => @level.game.id)
    response
  end
end
