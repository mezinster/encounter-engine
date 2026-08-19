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

  # A fourth history guard, added with AccessPass: a purchase record, so
  # holding one blocks deletion the same way a game_entry/game_passing/log
  # row does -- the team holds nothing else here, so this fails for the
  # access_passes conjunct alone.
  it "is false once it holds an access pass" do
    team = empty_team
    game = create_game(:is_draft => false, :access_mode => "pass_required")
    create_access_pass(:game => game, :team => team)

    expect(team.reload.deletable?).to be false
  end

  # A fifth history guard, added with the points ledger: a ledger row is a
  # record of something that happened, so holding one blocks deletion the
  # same way a game_entry/game_passing/log/access_pass row does.
  #
  # An ordinary point_transaction is always earned through a game_passing
  # belonging to the same team, so the existing game_passings.empty? conjunct
  # would already refuse deletion in that case -- it would not isolate this
  # new conjunct. Deleting the earning passing out from under its award (with
  # #delete, which skips callbacks/validations, standing in for a row a
  # console edit or a future cleanup task removed independently) leaves
  # game_passings empty while the ledger row remains, so only
  # point_transactions.empty? still refuses here.
  it "is false once it holds a point transaction, even with no game passing left to explain it" do
    team = empty_team
    passing = create_game_passing(:team => team)
    create_point_transaction(:passing => passing)
    passing.delete

    expect(team.reload.game_passings).to be_empty
    expect(team.point_transactions).not_to be_empty
    expect(team.deletable?).to be false
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
