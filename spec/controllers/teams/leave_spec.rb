# -*- encoding : utf-8 -*-
require "rails_helper"

# S3/D3 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
# Membership was one team per user, permanently: nothing anywhere set
# users.team_id back to nil, so ensure_not_member_of_any_team was a trap
# rather than a rule.
RSpec.describe TeamsController, "#leave", type: :controller do
  before :each do
    @captain = create_user
    @team = create_team(:captain => @captain)
    @member = create_user
    @team.members << @member
  end

  it "lets a plain member leave" do
    perform_request(:as_user => @member)

    expect(@member.reload.team).to be_nil
    expect(response).to redirect_to(dashboard_path)
  end

  it "leaves the team and its captain otherwise untouched" do
    perform_request(:as_user => @member)

    expect(@team.reload.captain).to eq(@captain)
    expect(@team.members).to eq([@captain])
  end

  it "refuses a captain who still has teammates" do
    perform_request(:as_user => @captain)

    expect(flash[:alert]).to eq(I18n.t("teams.hand_over_before_leaving"))
  end

  # Separate from the message above: RSpec fails fast, so a data assertion
  # after the flash check could never fail on its own.
  it "keeps a captain with teammates in their team" do
    perform_request(:as_user => @captain)

    expect(@captain.reload.team).to eq(@team)
    expect(@team.reload.captain).to eq(@captain)
  end

  # D5. There is nobody to hand to, so the role goes with them and the team
  # becomes an inert tombstone -- no members, no captain, all history intact.
  describe "a solo captain" do
    before :each do
      @solo = create_user
      @solo_team = create_team(:captain => @solo)
    end

    it "may leave" do
      perform_request(:as_user => @solo)

      expect(@solo.reload.team).to be_nil
    end

    # captain_id must be cleared too. Leaving it dangling would point
    # team.captain at someone who is no longer a member, while User#captain?
    # -- which reads through user.team -- says false: exactly the divergence
    # that makes the weak ensure_team_captain guard exploitable.
    it "leaves no dangling captain behind" do
      perform_request(:as_user => @solo)

      expect(@solo_team.reload.captain).to be_nil
      expect(@solo_team.members).to be_empty
    end
  end

  it "refuses anyone while the team is in a live race" do
    create_game_passing(:team => @team, :level => create_level)

    perform_request(:as_user => @member)

    expect(@member.reload.team).to eq(@team)
  end

  it "refuses a user who is in no team" do
    stray = create_user

    perform_request(:as_user => stray)

    expect(stray.reload.team).to be_nil
    expect(response).to redirect_to(dashboard_path)
  end

  it "refuses a guest" do
    assert_unauthenticated { perform_request }
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :leave
    response
  end
end
