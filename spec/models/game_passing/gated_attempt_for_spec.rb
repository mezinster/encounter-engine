require "rails_helper"

# Finding 3 of the whole-branch review: GamePassingsController#gated_passing,
# LogsController#gated_passing_for and InterventionsController#find_game_passing
# each invented their own resolution of "this team's gated attempt", and could
# disagree once a team held two. GamePassing.gated_attempt_for is now the one
# definition all three call, and this pins the resolution itself; a
# corresponding example in each controller's own spec pins that the call site
# actually uses it (see spec/requests/interventions_spec.rb,
# spec/requests/gated_log_scope_spec.rb, spec/requests/gated_play_spec.rb).
describe GamePassing, ".gated_attempt_for" do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }
  let(:team)  { create_team }

  def attempt_on(pass)
    create_game_passing(:game => game, :team => team, :level => level,
                        :game_run => nil, :access_pass => pass)
  end

  it "is nil for a team with no gated attempt" do
    expect(GamePassing.gated_attempt_for(game, team)).to be_nil
  end

  it "is nil for a nil team" do
    expect(GamePassing.gated_attempt_for(game, nil)).to be_nil
  end

  it "resolves a team's only attempt" do
    pass = create_access_pass(:game => game, :team => team)
    attempt = attempt_on(pass)

    expect(GamePassing.gated_attempt_for(game, team)).to eq(attempt)
  end

  # The scenario finding 3 names directly: an older, COMPLETED attempt and a
  # newer, live one. The unordered/misordered old forms could return either
  # -- under SQLite, the older one. This must always return the newer.
  it "resolves the newest attempt, not the oldest, when the team holds two" do
    old_pass = create_access_pass(:game => game, :team => team)
    old_attempt = attempt_on(old_pass)
    old_attempt.update!(:finished_at => 3.days.ago)

    new_pass = create_access_pass(:game => game, :team => team)
    new_attempt = attempt_on(new_pass)

    expect(GamePassing.gated_attempt_for(game, team)).to eq(new_attempt)
  end

  # Same claim as above, but with the newest attempt ALSO spent (exited),
  # proving this is genuinely "newest", not "the live one" with a different
  # implementation -- there is no live attempt here at all.
  it "resolves the newest attempt even when it too is spent" do
    old_pass = create_access_pass(:game => game, :team => team)
    old_attempt = attempt_on(old_pass)
    old_attempt.update!(:finished_at => 3.days.ago)

    new_pass = create_access_pass(:game => game, :team => team)
    new_attempt = attempt_on(new_pass)
    new_attempt.exit!

    expect(GamePassing.gated_attempt_for(game, team)).to eq(new_attempt)
  end

  it "ignores a stray runless passing that holds no access pass" do
    create_game_passing(:game => game, :team => team, :level => level, :game_run => nil)

    expect(GamePassing.gated_attempt_for(game, team)).to be_nil
  end

  it "accepts a raw team id, matching of_team's own flexibility" do
    pass = create_access_pass(:game => game, :team => team)
    attempt = attempt_on(pass)

    expect(GamePassing.gated_attempt_for(game, team.id)).to eq(attempt)
  end
end
