# -*- encoding : utf-8 -*-
require "rails_helper"

# Powers the mid-race refusal on captain self-service handover (D1 of
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md).
# Deliberately NOT applied to the superadmin path: the abandoned-captain
# problem is most acute mid-race, because quitting is itself captain-only.
#
# Verified against app/models/game_passing.rb rather than assumed, because
# the four terminal states are not symmetrical:
#
#   playing   status nil,      finished_at nil
#   exited    status "exited", finished_at set   (exit! writes both)
#   ended     status "ended",  finished_at nil   (end! writes status only)
#   finished  status nil,      finished_at set   (set_finish_time only)
#
# So each clause of the predicate has exactly one example that isolates it:
# "ended" is false only because of the status check, and "finished" is false
# only because of the finished_at check. The exited case is covered twice
# over and proves neither clause on its own.
RSpec.describe Team, "#in_live_race?" do
  it "is false for a team that has never entered a game" do
    team = create_team(:captain => create_user)

    expect(team.in_live_race?).to be false
  end

  it "is true while a passing is under way" do
    team = create_team(:captain => create_user)
    create_game_passing(:team => team, :level => create_level)

    expect(team.reload.in_live_race?).to be true
  end

  it "is false once the team has quit the race" do
    team = create_team(:captain => create_user)
    passing = create_game_passing(:team => team, :level => create_level)
    passing.exit!

    expect(team.reload.in_live_race?).to be false
  end

  # Isolates the status clause: end! leaves finished_at nil.
  it "is false once the author has ended the game" do
    team = create_team(:captain => create_user)
    passing = create_game_passing(:team => team, :level => create_level)
    passing.end!

    expect(team.reload.in_live_race?).to be false
  end

  # Isolates the finished_at clause: a team that crossed the line keeps a nil
  # status, so status alone would report them as still racing hours later.
  it "is false once the team has finished" do
    team = create_team(:captain => create_user)
    passing = create_game_passing(:team => team, :level => create_level)
    passing.update!(:finished_at => Time.now)

    expect(team.reload.in_live_race?).to be false
  end

  # A team can hold passings for several games at once, so the predicate has
  # to be "any live one", not "the latest one".
  it "is true when only one of several passings is live" do
    team = create_team(:captain => create_user)
    old = create_game_passing(:team => team, :level => create_level)
    old.exit!
    create_game_passing(:team => team, :level => create_level)

    expect(team.reload.in_live_race?).to be true
  end
end
