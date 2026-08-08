require "rails_helper"

# Proves the chain the design claims, rather than asserting its two halves
# separately.
#
# Phase 1 guarded NotificationMailer against a captainless team, and at the
# time nothing in the app could produce one -- the guard was precautionary.
# Phase 4's D5 changes that: a solo captain leaving takes the role with them,
# so captain_id IS NULL becomes reachable through the UI for the first time.
#
# An earlier version of this spec set captain_id to nil directly and passed
# even when the leave action was mutated to leave a dangling captain behind.
# It looked like coverage of the chain and was really coverage of one link.
# This one walks the whole path: invite, leave, accept.
describe "a team that lost its captain to a solo departure", type: :request do
  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). create_user sets the
  # password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "still lets an outstanding invitation be accepted, with no partial commit" do
    solo = create_user
    team = create_team(:captain => solo)
    invitee = create_user
    invitation = create_invitation(:for => invitee, :from => team)

    sign_in(solo)
    post leave_teams_path
    expect(solo.reload.team).to be_nil
    expect(team.reload.captain).to be_nil

    sign_in(invitee)
    expect { post accept_invitation_path(invitation) }.not_to raise_error

    # Without NotificationMailer's guard this raised NoMethodError AFTER the
    # join and AFTER the invitation row was deleted, so the assertions below
    # are what distinguish "completed" from "half-completed and 500'd".
    expect(invitee.reload.team).to eq(team)
    expect(Invitation.find_by(:id => invitation.id)).to be_nil
  end
end
