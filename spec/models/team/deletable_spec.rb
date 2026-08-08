# -*- encoding : utf-8 -*-
require "rails_helper"

# D5 left an empty, captainless team behind as an inert tombstone whose name
# stays reserved forever. This is the narrow way to reclaim one: a team that
# never played anything and now has nobody in it.
#
# Deliberately narrow. Six tables carry a team_id, and three of them --
# game_entries, game_passings and logs -- are records of races other people
# ran. Deleting those is the same objection that rules out deleting authored
# games, so a team that ever entered a game is never deletable, no matter how
# empty it is now.
RSpec.describe Team, "#deletable?" do
  it "is true for an empty, captainless team that never played" do
    team = create_team(:captain => create_user)
    team.update!(:captain => nil)
    team.members.each { |member| member.update!(:team => nil) }

    expect(team.reload.deletable?).to be true
  end

  it "is false while anyone is still a member" do
    team = create_team(:captain => create_user)
    team.update!(:captain => nil)

    expect(team.reload.deletable?).to be false
  end

  it "is false while it still has a captain" do
    team = create_team(:captain => create_user)

    expect(team.deletable?).to be false
  end

  # The example above does NOT isolate the captain check -- mutation showed
  # that dropping it entirely leaves every example green, because a captain is
  # always a member (phase 1 validates it, adopt_captain enforces it), so
  # members.empty? already excludes any team with a live captain.
  #
  # What the captain check actually defends is the state that invariant
  # forbids: a captain_id pointing at somebody who is not a member. Phase 1
  # made that unreachable through the model, so it is built here with
  # update_column, which bypasses validation -- the shape a legacy row, a
  # restored backup or a console edit could still hold. Deleting such a team
  # would leave that user's team_id fine but destroy the row their captaincy
  # pointed at.
  it "is false when captain_id dangles at a non-member, which validation now forbids" do
    team = empty_team
    outsider = create_user

    team.update_column(:captain_id, outsider.id)

    expect(team.reload.members).to be_empty
    expect(team.deletable?).to be false
  end

  # The three history guards. Each is its own example so a partial
  # implementation cannot pass.
  it "is false once it has entered a game" do
    team = empty_team
    GameEntry.create!(:game => create_game, :team => team, :status => "new")

    expect(team.reload.deletable?).to be false
  end

  it "is false once it has a game passing" do
    team = empty_team
    create_game_passing(:team => team, :level => create_level)

    expect(team.reload.deletable?).to be false
  end

  it "is false once it appears in the answer log" do
    team = empty_team
    Log.create!(:game => create_game, :team_id => team.id, :team => team.name,
                :level => "L1", :answer => "x", :time => Time.now)

    expect(team.reload.deletable?).to be false
  end

  # Invitations and join requests are meaningless once the team is gone, and
  # a dangling one breaks the dashboard, which renders invitation.to_team.name.
  # So they travel with it rather than blocking it.
  it "is deletable despite a pending invitation, and takes it along" do
    team = empty_team
    invitation = Invitation.create!(:to_team => team,
                                    :recepient_nickname => create_user.nickname)

    expect(team.deletable?).to be true
    team.destroy
    expect(Invitation.find_by(:id => invitation.id)).to be_nil
  end

  it "is deletable despite a pending join request, and takes it along" do
    team = empty_team
    request = TeamJoinRequest.create!(:user => create_user, :team => team)

    expect(team.deletable?).to be true
    team.destroy
    expect(TeamJoinRequest.find_by(:id => request.id)).to be_nil
  end

  # An empty, captainless team is exactly what a solo captain leaving (D5)
  # produces, so the tombstone that motivated this is deletable by definition.
  def empty_team
    team = create_team(:captain => create_user)
    team.update!(:captain => nil)
    team.members.each { |member| member.update!(:team => nil) }
    team.reload
  end
end
