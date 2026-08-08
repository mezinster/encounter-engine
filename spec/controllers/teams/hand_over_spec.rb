# -*- encoding : utf-8 -*-
require "rails_helper"

# D2 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md:
# a captain may hand over voluntarily. Guarded by the STRICT pattern -- the
# team comes from the URL and the actor must be that team's captain -- not by
# SecurityFilters#ensure_team_captain, which only asks "is this user *a*
# captain" and derives the team from current_user, so it would admit the
# captain of any other team to this action.
RSpec.describe TeamsController, "#hand_over", type: :controller do
  before :each do
    @captain = create_user
    @team = create_team(:captain => @captain)
    @successor = create_user
    @team.members << @successor
  end

  it "moves captaincy to the chosen member" do
    perform_request(:as_user => @captain, :member_id => @successor.id)

    expect(@team.reload.captain).to eq(@successor)
    expect(@successor.reload.captain?).to be true
    expect(response).to redirect_to(team_room_path)
  end

  # There is no way to remove anyone from a team, and phase 2 deliberately
  # does not add one -- leaving is phase 4.
  it "leaves the outgoing captain in the team as a plain member" do
    perform_request(:as_user => @captain, :member_id => @successor.id)

    expect(@team.reload.members).to include(@captain)
    expect(@captain.reload.captain?).to be false
  end

  # D1: member-initiated changes wait for the race to end. The superadmin
  # path is deliberately NOT guarded this way -- see admin_teams_spec, which
  # pins the other side of the asymmetry.
  it "refuses while the team is in a live race" do
    create_game_passing(:team => @team, :level => create_level)

    perform_request(:as_user => @captain, :member_id => @successor.id)

    expect(@team.reload.captain).to eq(@captain)
    expect(flash[:alert]).to eq(I18n.t("teams.cannot_hand_over_mid_race"))
  end

  it "refuses a plain member of the same team" do
    assert_unauthorized { perform_request(:as_user => @successor, :member_id => @captain.id) }
    expect(@team.reload.captain).to eq(@captain)
  end

  # The reason the guard has to be strict rather than reusing
  # ensure_team_captain: a captain of a DIFFERENT team must not be able to
  # hand over this one.
  it "refuses the captain of another team" do
    intruder = create_user
    create_team(:captain => intruder)

    assert_unauthorized { perform_request(:as_user => intruder, :member_id => @successor.id) }
    expect(@team.reload.captain).to eq(@captain)
  end

  # Deliberately separate from the two refusal examples above, which swallow
  # nothing: assert_unauthorized asserts the status itself, so it fails first
  # and the "captaincy unchanged" line after it never runs. Mutation proved
  # that: swapping the strict guard for the weak current_user.captain? makes
  # an outside captain reassign this team for real, and the only assertion
  # that fired was the status one. This example is what pins the data.
  #
  # Same lesson as phase 1's set_captain_spec -- an assertion sitting after a
  # status or raise expectation in the same example cannot fail on its own.
  it "does not let an outside captain change this team's captain" do
    intruder = create_user
    create_team(:captain => intruder)

    begin
      perform_request(:as_user => intruder, :member_id => @successor.id)
    rescue Authentication::Unauthorized
      # The refusal is asserted above; here only its side effects matter.
    end

    expect(@team.reload.captain).to eq(@captain)
    expect(@successor.reload.captain?).to be false
  end

  it "refuses a guest" do
    assert_unauthenticated { perform_request(:member_id => @successor.id) }
    expect(@team.reload.captain).to eq(@captain)
  end

  it "refuses handing over to a user who is not a member, without stealing them" do
    outsider = create_user

    perform_request(:as_user => @captain, :member_id => outsider.id)

    expect(@team.reload.captain).to eq(@captain)
    expect(outsider.reload.team).to be_nil
  end

  it "refuses handing over to oneself" do
    perform_request(:as_user => @captain, :member_id => @captain.id)

    expect(@team.reload.captain).to eq(@captain)
    expect(flash[:alert]).to eq(I18n.t("teams.hand_over_needs_another_member"))
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    session[:session_token] = opts[:as_user]&.session_token
    post :hand_over, params: { id: @team.id, member_id: opts[:member_id] }
    response
  end
end
