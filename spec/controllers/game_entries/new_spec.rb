# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe GameEntriesController, "#new", type: :controller do
  describe "security filters" do
    before :each do
      @game = create_game
      @team = create_team
    end

    it "raises Unauthenticated exception for a guest" do
      assert_unauthenticated { perform_request }
    end

    it "raises Unauthorized exception for a logged-in user who is not a team captain" do
      user = create_user
      assert_unauthorized { perform_request(:as_user => user) }
    end
  end

  describe "when the game still has room for another team" do
    before :each do
      @captain = create_user
      @team = create_team :captain => @captain
      @game = create_game :max_team_number => 5, :requested_teams_number => 0
    end

    it "creates a new game entry with status 'new'" do
      expect do
        perform_request :as_user => @captain
      end.to change(GameEntry, :count).by(1)

      expect(GameEntry.last.status).to eq("new")
      expect(GameEntry.last.team.id).to eq(@team.id)
      expect(GameEntry.last.game.id).to eq(@game.id)
    end

    it "reserves a place for the team" do
      perform_request :as_user => @captain
      expect(@game.reload.requested_teams_number).to eq(1)
    end

    it "redirects to the dashboard" do
      perform_request :as_user => @captain
      expect(response).to redirect_to(dashboard_path)
    end
  end

  # GameEntry has no unique index on (team_id, game_id), and this action
  # creates a fresh row on every hit -- so a captain double-clicking "apply",
  # or two near-simultaneous requests, could leave a team holding two
  # entries for the same game (see the comment on GameEntry.of).
  describe "when the team already has an entry for this game" do
    before :each do
      @captain = create_user
      @team = create_team :captain => @captain
      @game = create_game :max_team_number => 5, :requested_teams_number => 0
    end

    it "does not create a second entry on a double submission" do
      expect do
        2.times { perform_request :as_user => @captain }
      end.to change(GameEntry, :count).by(1)
    end

    it "does not reserve a place twice on a double submission" do
      2.times { perform_request :as_user => @captain }

      expect(@game.reload.requested_teams_number).to eq(1)
    end

    it "does not create a duplicate row when an entry already exists in another status" do
      GameEntry.create!(:game => @game, :game_run => @game.current_run,
                        :team => @team, :status => "rejected")

      expect do
        perform_request :as_user => @captain
      end.not_to change(GameEntry, :count)
    end
  end

  # There is no equivalent "game has no room left" example here: Game#can_request?
  # (app/models/game.rb) now correctly returns
  # `requested_teams_number < max_team_number`, and the server-side cap it
  # backs is exercised at the request level, not here -- see
  # spec/requests/game_capacity_spec.rb:15 ("refuses a registration once the
  # cap is reached"), which asserts exactly that and passes.

  def perform_request(opts = {})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    get :new, params: { game_id: @game.id, team_id: @team.id }
    response
  end
end
