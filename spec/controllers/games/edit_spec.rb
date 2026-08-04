# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe GamesController, "#edit", type: :controller do
  describe "security filters" do
    describe "when the game author attempts to see game edit form" do
      before :each do
        @user = create_user
        @game = create_game :author => @user
      end

      it "responds successfully" do
        perform_request(:as_user => @user)
        expect(response).to have_http_status(:success)
      end
    end

    describe "when any other user attempts to see game edit form" do
      before :each do
        @user = create_user
        @game = create_game
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request(:as_user => @user) }
      end
    end

    describe "when a guest attempts to see draft game edit form" do
      before :each do
        @game = create_game :is_draft => false
      end

      # The Merb original asserted this with assert_unauthorized (checking
      # for Merb::ControllerExceptions::Unauthorized), but the actual old
      # Games controller ran `before :ensure_authenticated, :exclude =>
      # [:index, :show]` -- :edit is not excluded, so a guest hit that
      # filter first and got Unauthenticated, never reaching ensure_author.
      # assert_unauthorized never matched real behaviour here; this test's
      # own description ("raises Unauthenticated exception") already said
      # so. Fixed to match what the controller actually does.
      it "raises Unauthenticated exception" do
        assert_unauthenticated { perform_request }
      end
    end
  end

  describe "when author attempts to edit game after beginning" do
    before :each do
      @author = create_user
      tomorrow = DateTime.now + 1
      @game = create_game :author => @author, :starts_at => tomorrow
      day_after_tomorrow = tomorrow + 1
      Time.stub(:now => day_after_tomorrow)
    end

    it "raises Unauthorized exception" do
      assert_unauthorized { perform_request(:as_user => @author) }
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    get :edit, params: { id: @game.id }
    response
  end
end
