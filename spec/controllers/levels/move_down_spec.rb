# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe LevelsController, "#move_down", type: :controller do
  before :each do
    @level = create_level
  end

  describe "security filters" do
    describe "when any other user attempts to move a level down" do
      before :each do
        @user = create_user
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request(:as_user => @user) }
      end
    end

    describe "when a guest attempts to move a level" do
      # LevelsController has no separate authentication filter -- ensure_author
      # (see app/controllers/concerns/security_filters.rb) rejects a guest
      # with the same Unauthorized response as a logged-in non-author, so
      # this is genuinely Unauthorized, not Unauthenticated (the old test's
      # description said otherwise, but its assert_unauthorized call matched
      # the real Merb behaviour -- only the title was wrong).
      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request }
      end
    end
  end

  describe "when authour moves level down correctly" do
    before :each do
      @author = create_user
      @game = create_game :author => @author
      create_level :game => @game
      @level = create_level :game => @game
      create_level :game => @game
      @initial_level_position = @level.position

    end

    it "actually moves level down" do
      expect do
        perform_request :as_user => @author
      end.to change { @level.reload.position }.by(1)
    end
  end

  def perform_request(opts={}, params={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :move_down, params: params.merge(:id => @level.id, :game_id => @level.game.id)
    response
  end
end
