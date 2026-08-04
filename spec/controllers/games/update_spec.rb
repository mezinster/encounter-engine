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

      # See games/edit_spec.rb for the full explanation: under Merb,
      # Unauthenticated is a subclass of Unauthorized, so assert_unauthorized
      # matched here too even though ensure_authenticated (not ensure_author)
      # is what actually rejects a guest. Rails' two exception classes are
      # unrelated (separate rescue_from handlers, redirect vs. 401), so the
      # assertion has to name the one that's actually raised -- still
      # Unauthenticated, since :update is not excluded from
      # require_authentication!.
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
