# -*- encoding : utf-8 -*-
require "rails_helper"

# F1 of the team membership programme: the single operation through which
# captaincy ever changes. See
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
RSpec.describe Team, "#set_captain!" do
  it "moves captaincy to another member of the same team" do
    old_captain = create_user
    successor = create_user
    team = create_team(:captain => old_captain)
    team.members << successor

    team.set_captain!(successor)

    expect(team.reload.captain).to eq(successor)
    expect(successor.reload.captain?).to be true
    expect(old_captain.reload.captain?).to be false
  end

  # The outgoing captain stays a member -- there is no way to remove anyone
  # from a team, and Phase 1 deliberately does not add one.
  it "leaves the outgoing captain in the team" do
    old_captain = create_user
    successor = create_user
    team = create_team(:captain => old_captain)
    team.members << successor

    team.set_captain!(successor)

    expect(team.reload.members).to include(old_captain)
    expect(old_captain.reload.team).to eq(team)
  end

  # The landmine this operation exists to disarm: Team#adopt_captain does
  # `members << captain` with no validation, and members is has_many :users,
  # so handing captaincy to an outsider would overwrite that user's team_id
  # and steal them out of their own team -- silently, with no error and no
  # notification to the team they were taken from.
  it "refuses a user who is not a member, and does not steal them" do
    old_captain = create_user
    outsider = create_user
    other_team = create_team(:captain => outsider)
    team = create_team(:captain => old_captain)

    expect { team.set_captain!(outsider) }.to raise_error(ArgumentError)

    expect(team.reload.captain).to eq(old_captain)
    expect(outsider.reload.team).to eq(other_team)
  end

  # Deliberately a separate example that swallows the refusal rather than
  # asserting it. In the example above, RSpec fails fast on the raise_error
  # expectation, so the "was not stolen" assertion never runs and cannot
  # catch anything on its own. Mutation showed both plausible wrong
  # implementations -- no guard at all, and a guard placed after the write --
  # failing on the missing raise while the theft went unexamined. Worse, the
  # guard-after-write version never raises either: adopt_captain adds the
  # outsider to members during the save, so the post-write membership check
  # finds them present and the callback quietly legitimises the theft it
  # should have exposed. This example is what actually pins the property.
  it "does not move an outsider into this team when the attempt is refused" do
    old_captain = create_user
    outsider = create_user
    other_team = create_team(:captain => outsider)
    team = create_team(:captain => old_captain)

    begin
      team.set_captain!(outsider)
    rescue ArgumentError
      # The refusal itself is asserted above; here only its side effects matter.
    end

    expect(outsider.reload.team).to eq(other_team)
    expect(team.reload.members).not_to include(outsider)
  end

  it "refuses a teamless user who is not a member" do
    old_captain = create_user
    stranger = create_user
    team = create_team(:captain => old_captain)

    expect { team.set_captain!(stranger) }.to raise_error(ArgumentError)

    expect(team.reload.captain).to eq(old_captain)
    expect(stranger.reload.team).to be_nil
  end
end
