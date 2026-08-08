# -*- encoding : utf-8 -*-
require "rails_helper"

# The only code in the app that sets a captain had no controller spec.
# Written before Phase 1 touches Team's captain handling, because team
# creation DEPENDS on the adopt_captain callback: TeamsController#create
# assigns a captain who has no team_id yet, and the after_save is what makes
# the creator a member. See
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md (F2).
RSpec.describe TeamsController, "#create", type: :controller do
  describe "a fresh user creates a team" do
    before :each do
      @user = create_user
      perform_request(:as_user => @user, :name => "Мухоморы")
    end

    it "creates the team and redirects to the dashboard" do
      expect(Team.find_by(:name => "Мухоморы")).not_to be_nil
      expect(response).to redirect_to(dashboard_path)
    end

    # This is the behaviour Task 4's validation must preserve.
    it "makes the creator both the captain and a member of the new team" do
      team = Team.find_by(:name => "Мухоморы")
      expect(team.captain).to eq(@user)
      expect(team.members).to include(@user)
      expect(@user.reload.team).to eq(team)
      expect(@user.captain?).to be true
    end
  end

  describe "a guest attempts to create a team" do
    it "is sent to login and creates nothing" do
      expect do
        assert_unauthenticated { perform_request(:name => "Мухоморы") }
      end.not_to change(Team, :count)
    end
  end

  describe "a member of some team attempts to create another" do
    before :each do
      @user = create_user
      @team = create_team(:captain => @user)
    end

    it "refuses and creates nothing" do
      expect { perform_request(:as_user => @user, :name => "Вторая") }
        .not_to change(Team, :count)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :create, params: { team: { name: opts[:name] } }
    response
  end
end
