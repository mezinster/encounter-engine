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

  # There is no equivalent "game has no room left" example here: Game#can_request?
  # (app/models/game.rb) now correctly returns
  # `requested_teams_number < max_team_number`, and the server-side cap it
  # backs is exercised at the request level, not here -- see
  # spec/requests/game_capacity_spec.rb:15 ("refuses a registration once the
  # cap is reached"), which asserts exactly that and passes.

  def perform_request(opts = {})
    session[:user_id] = opts[:as_user]&.id
    get :new, params: { game_id: @game.id, team_id: @team.id }
    response
  end
end
