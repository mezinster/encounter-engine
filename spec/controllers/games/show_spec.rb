# -*- encoding : utf-8 -*-
require "rails_helper"

# New in fix round 1: the initial port of GamesController dropped the three
# #show-only filters the Merb original had (find_team,
# ensure_author_if_game_is_draft, ensure_author_if_no_start_time -- see
# master:app/controllers/games.rb:6-8). Without them a guest could GET
# /games/:id on an unpublished draft, or on a game with no start_at yet, and
# see its name/description/level count before the author meant it to be
# public. These specs cover the restored guards.
RSpec.describe GamesController, "#show", type: :controller do
  describe "when a guest attempts to view a draft game" do
    before :each do
      @game = create_game :is_draft => true
    end

    it "raises Unauthorized exception" do
      assert_unauthorized { perform_request }
    end
  end

  describe "when a guest attempts to view a game with no start time" do
    before :each do
      @game = create_game :starts_at => nil
    end

    it "raises Unauthorized exception" do
      assert_unauthorized { perform_request }
    end
  end

  describe "when a logged-in non-author attempts to view a draft game" do
    before :each do
      @user = create_user
      @game = create_game :is_draft => true
    end

    it "raises Unauthorized exception" do
      assert_unauthorized { perform_request(:as_user => @user) }
    end
  end

  describe "when the author views their own draft game" do
    before :each do
      @user = create_user
      @game = create_game :author => @user, :is_draft => true
    end

    it "responds successfully" do
      perform_request(:as_user => @user)
      expect(response).to have_http_status(:success)
    end
  end

  describe "when the author views their own game with no start time" do
    before :each do
      @user = create_user
      @game = create_game :author => @user, :starts_at => nil
    end

    it "responds successfully" do
      perform_request(:as_user => @user)
      expect(response).to have_http_status(:success)
    end
  end

  describe "when anyone views a published, scheduled game" do
    before :each do
      @game = create_game :is_draft => false
    end

    it "responds successfully to a guest" do
      perform_request
      expect(response).to have_http_status(:success)
    end
  end

  # A gated game legitimately has no start time -- it never gets one -- so
  # ensure_author_if_no_start_time treating that as "not yet scheduled,
  # author only" would 401 the game's own paying customers. Unlike the
  # ordinary "no start time" case above, a guest here must succeed.
  describe "when a guest attempts to view a published, gated game with no start time" do
    before :each do
      @game = create_game :is_draft => false, :starts_at => nil,
                          :access_mode => "pass_required"
    end

    it "responds successfully" do
      perform_request
      expect(response).to have_http_status(:success)
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    get :show, params: { id: @game.id }
    response
  end
end
