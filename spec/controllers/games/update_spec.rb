# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe GamesController, "#update", type: :controller do
  describe "security filters" do
    describe "when the game author attempts to update game" do
      before :each do
        @user = create_user
        @game = create_game :author => @user, :is_draft => false
      end

      it "redirects"
    end

    describe "when any other user attempts to update game" do
      before :each do
        @user = create_user
        @game = create_game :is_draft => false
      end

      it "raises Unauthorized exception" do
        assert_unauthorized { perform_request(:as_user => @user) }
      end
    end

    describe "when a guest attempts to update game" do
      before :each do
        @game = create_game :is_draft => false
      end

      # See the equivalent note in games/edit_spec.rb: the old Games
      # controller runs ensure_authenticated (excluding only index/show)
      # before ensure_author, so a guest gets Unauthenticated here too --
      # assert_unauthorized (checking for Unauthorized) never matched actual
      # behaviour. Fixed to match the description and the real filter order.
      it "raises Unauthenticated exception" do
        assert_unauthenticated { perform_request }
      end
    end
  end

  describe "when author attempts to update game after beginning" do
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
    patch :update, params: { id: @game.id }
    response
  end
end
