require "rails_helper"

# "Access this team paid for and has not had the benefit of yet" -- the
# population an operator must deal with before they may stop selling access to
# a game (Game#access_still_owed).
#
# Deliberately NOT #live?, and the difference is one state. live? is
# "not revoked and not spent", which is the right question for "may this team
# start playing". This one asks "does someone still owe this team something",
# and an attempt the OPERATOR ended is the case where the two answers differ:
# end! leaves finished_at nil on purpose (see GamePassing#end! and
# AccessPass#spent?), so such a pass is live for ever -- it can never be spent,
# and AccessPassesController#destroy refuses to revoke a pass whose attempt
# exists. Treating it as owed would make the game permanently unconvertible,
# with no action available to anybody to unblock it.
describe AccessPass, "#outstanding?" do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required"); g }
  let(:team)  { create_team }
  let(:pass)  { create_access_pass(:game => game, :team => team) }

  def attempt_for(pass)
    create_game_passing(:game => pass.game, :team => pass.team, :level => level,
                        :game_run => nil, :access_pass => pass)
  end

  it "is true for access nobody has started using" do
    expect(pass.outstanding?).to be true
  end

  it "is true while the team is mid-attempt" do
    attempt_for(pass)

    expect(pass.reload.outstanding?).to be true
  end

  it "is false once the team completes the course" do
    attempt_for(pass).update!(:finished_at => Time.now)

    expect(pass.reload.outstanding?).to be false
  end

  # exit! stamps finished_at as well as the status, so quitting spends the
  # pass -- the team had their go and gave up. Nothing is owed.
  it "is false once the team quits" do
    attempt = attempt_for(pass)
    attempt.exit!

    expect(pass.reload.outstanding?).to be false
  end

  # The state live? and outstanding? disagree about, and the whole reason
  # this predicate exists rather than reusing live?.
  it "is false for an attempt the operator ended, though the pass stays live" do
    attempt = attempt_for(pass)
    attempt.end!

    expect(pass.reload.live?).to be true
    expect(pass.reload.outstanding?).to be false
  end

  it "is false once revoked" do
    pass.update!(:revoked_at => Time.now)

    expect(pass.outstanding?).to be false
  end

  # Loaded and filtered in Ruby for the same reason AccessPass.next_for is
  # (see its comment): liveness depends on the attempt through a LEFT JOIN, a
  # game holds a handful of passes, and a SQL form would restate the encoding
  # in a second place. Preloaded so the filter is one query, not N.
  describe ".outstanding_for" do
    it "returns only the passes that are still owed" do
      owed      = pass
      completed = create_access_pass(:game => game, :team => create_team)
      attempt_for(completed).update!(:finished_at => Time.now)
      revoked   = create_access_pass(:game => game, :team => create_team)
      revoked.update!(:revoked_at => Time.now)

      expect(AccessPass.outstanding_for(game)).to eq([owed])
    end

    it "is empty for a game that never sold any" do
      expect(AccessPass.outstanding_for(create_game)).to be_empty
    end
  end
end
