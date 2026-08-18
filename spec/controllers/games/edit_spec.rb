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

      # The Merb original asserted this with assert_unauthorized. That
      # worked under Merb even though the guest actually raises
      # Unauthenticated (ensure_authenticated runs before ensure_author for
      # :edit -- see the old `before :ensure_authenticated, :exclude =>
      # [:index, :show]`): Merb::Controller::Unauthenticated is a *subclass*
      # of ControllerExceptions::Unauthorized (merb-auth-
      # core/lib/merb-auth-core/authenticated_helper.rb:2, removed by Task 13;
      # see git history), so
      # raise_error(Unauthorized) matched either exception. Rails'
      # Authentication::Unauthenticated and Authentication::Unauthorized
      # (app/controllers/concerns/authentication.rb) have no such
      # relationship -- both are plain StandardError with separate
      # rescue_from handlers (redirect vs. 401) -- so the assertion has to
      # name whichever one is actually raised. That's still Unauthenticated
      # here, matching this test's own description.
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

  # ensure_game_was_not_started reads @game.started?, and a gated game's
  # starts_at is meaningless -- it has no schedule to "begin". Without this
  # exemption a gated game whose (irrelevant) starts_at happened to be in the
  # past became permanently uneditable for its own author, the moment the
  # clock passed a date nobody was tracking.
  describe "when author attempts to edit a gated game whose starts_at is in the past" do
    before :each do
      @author = create_user
      @game = create_game :author => @author, :starts_at => 1.hour.ago,
                          :access_mode => "pass_required"
    end

    it "responds successfully" do
      perform_request(:as_user => @author)
      expect(response).to have_http_status(:success)
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    get :edit, params: { id: @game.id }
    response
  end
end
