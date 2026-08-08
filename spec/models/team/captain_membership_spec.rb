# -*- encoding : utf-8 -*-
require "rails_helper"

# F2 of the team membership programme. Team#adopt_captain does
# `members << captain` on every after_save with no validation, and members is
# has_many :users -- so assigning an outsider as captain silently overwrote
# their users.team_id and moved them out of their own team, with no error and
# no notification to the team they were taken from.
#
# Nothing pinned that behaviour: spec/models/team/filters_spec.rb's
# "external" captain is built with a bare create_user and is therefore
# TEAMLESS, so it exercises the adopt path, never the steal path.
#
# Refusing the save is deliberately preferred to merely skipping the
# adoption. Skipping would leave captain_id pointing at a non-member, and
# User#captain? reads through user.team rather than teams.captain_id, so the
# two would disagree -- which is precisely the divergence that makes the weak
# SecurityFilters#ensure_team_captain guard exploitable.
RSpec.describe Team, "captain membership" do
  it "refuses a captain who already belongs to another team" do
    victim = create_user
    other_team = create_team(:captain => victim)
    team = create_team(:captain => create_user)

    team.captain = victim

    expect(team.save).to be false
    expect(victim.reload.team).to eq(other_team)
  end

  # Load-bearing for TeamsController#create, where the creator has no team_id
  # yet and adopt_captain is what makes them a member. Pinned end-to-end by
  # spec/controllers/teams/create_spec.rb.
  it "accepts a teamless captain and adopts them into the team" do
    founder = create_user
    team = Team.new(:name => "Новая команда", :captain => founder)

    expect(team.save).to be true
    expect(team.members).to include(founder)
    expect(founder.reload.team).to eq(team)
  end

  it "still accepts re-saving a team whose captain is already its member" do
    captain = create_user
    team = create_team(:captain => captain)

    team.name = "Переименованная"

    expect(team.save).to be true
    expect(team.reload.captain).to eq(captain)
  end
end
