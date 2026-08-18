require "rails_helper"

describe Game do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }

  def completed_attempt(seconds, paused: 0, penalty: 0)
    pass    = create_access_pass(:game => game)
    started = 3.days.ago
    attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                  :game_run => nil, :access_pass => pass)
    attempt.update_columns(:created_at => started,
                           :finished_at => started + seconds,
                           :paused_seconds => paused,
                           :penalty_seconds => penalty)
    attempt
  end

  describe "GamePassing#duration" do
    it "is finish minus start" do
      expect(completed_attempt(600).duration).to be_within(1).of(600)
    end

    it "subtracts time the game was paused" do
      expect(completed_attempt(600, paused: 120).duration).to be_within(1).of(480)
    end

    it "adds accrued penalties" do
      expect(completed_attempt(600, penalty: 60).duration).to be_within(1).of(660)
    end

    it "is nil for an unfinished attempt" do
      pass = create_access_pass(:game => game)
      attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                    :game_run => nil, :access_pass => pass)
      expect(attempt.duration).to be_nil
    end
  end

  describe "#pass_standings" do
    it "orders by duration, fastest first" do
      slow = completed_attempt(900)
      fast = completed_attempt(300)

      expect(game.pass_standings).to eq([ fast, slow ])
    end

    it "excludes an attempt that is still running" do
      pass = create_access_pass(:game => game)
      create_game_passing(:game => game, :team => pass.team, :level => level,
                          :game_run => nil, :access_pass => pass)

      expect(game.pass_standings).to be_empty
    end

    # exit! sets finished_at, so an abandoned attempt must be excluded by
    # status, not by finished_at alone.
    it "excludes an attempt the team abandoned" do
      attempt = completed_attempt(300)
      attempt.exit!

      expect(game.pass_standings).to be_empty
    end

    # B7: a row is an attempt, not a team.
    it "lists the same team twice when it completed two passes" do
      team = create_team
      a = completed_attempt(300); a.update!(:team => team)
      b = completed_attempt(900); b.update!(:team => team)

      expect(game.pass_standings.map(&:team_id)).to eq([ team.id, team.id ])
    end
  end
end
