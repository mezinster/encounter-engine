# -*- encoding : utf-8 -*-
require "rails_helper"

# S4 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
# The user -> captain direction, which Invitation cannot express: it is
# captain -> user, keyed by recepient_nickname, and it validates
# recepient_is_not_member_of_any_team -- a rule three frozen scenarios in
# features/invitations/send-invitations.feature pin, and which a transfer
# request would have to relax.
#
# Status shape mirrors GameEntry: "new" on creation, then accepted or
# rejected.
RSpec.describe TeamJoinRequest do
  before :each do
    @applicant = create_user
    @team = create_team(:captain => create_user)
  end

  it "starts out pending" do
    request = TeamJoinRequest.create!(:user => @applicant, :team => @team)

    expect(request.status).to eq("new")
    expect(TeamJoinRequest.pending).to include(request)
  end

  it "moves to accepted" do
    request = TeamJoinRequest.create!(:user => @applicant, :team => @team)

    request.accept!

    expect(request.reload.status).to eq("accepted")
    expect(TeamJoinRequest.pending).not_to include(request)
  end

  it "moves to rejected" do
    request = TeamJoinRequest.create!(:user => @applicant, :team => @team)

    request.reject!

    expect(request.reload.status).to eq("rejected")
    expect(TeamJoinRequest.pending).not_to include(request)
  end

  # The partial unique index, mirroring the one PR #42 added to game_entries
  # and for the same reason: a double-clicked button must not create two live
  # rows.
  it "refuses a second pending request to the same team" do
    TeamJoinRequest.create!(:user => @applicant, :team => @team)

    expect do
      TeamJoinRequest.create!(:user => @applicant, :team => @team)
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # ...but the index is scoped to the live status, so history stays legal: a
  # refused applicant may apply again later. A blanket unique index would
  # lock them out permanently, which is the trap the game_entries version
  # documents.
  it "allows a fresh request once an earlier one was rejected" do
    TeamJoinRequest.create!(:user => @applicant, :team => @team).reject!

    expect do
      TeamJoinRequest.create!(:user => @applicant, :team => @team)
    end.not_to raise_error
  end

  it "scopes by applicant and by team" do
    mine = TeamJoinRequest.create!(:user => @applicant, :team => @team)
    other = TeamJoinRequest.create!(:user => create_user, :team => @team)

    expect(TeamJoinRequest.of_user(@applicant)).to eq([mine])
    expect(TeamJoinRequest.to_team(@team)).to include(mine, other)
  end
end
