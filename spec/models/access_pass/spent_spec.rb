require "rails_helper"

describe AccessPass do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required"); g }
  let(:team)  { create_team }
  let(:pass)  { create_access_pass(:game => game, :team => team) }

  def attempt_for(pass)
    create_game_passing(:game => pass.game, :team => pass.team, :level => level,
                        :game_run => nil, :access_pass => pass)
  end

  describe "#spent?" do
    it "is false with no attempt yet" do
      expect(pass.spent?).to be false
      expect(pass.live?).to be true
    end

    it "is false while the attempt is in progress" do
      attempt_for(pass)
      expect(pass.reload.spent?).to be false
    end

    it "is true once the team completes the course" do
      attempt = attempt_for(pass)
      attempt.update!(:finished_at => Time.now)
      expect(pass.reload.spent?).to be true
    end

    it "is true once the team quits" do
      attempt = attempt_for(pass)
      attempt.exit!
      expect(pass.reload.spent?).to be true
    end

    # P3: who ended it decides who pays. end! is the operator closing the
    # game, and it leaves finished_at nil -- the customer did not get their
    # run, so the pass is not spent.
    it "is FALSE when an operator ends the game" do
      attempt = attempt_for(pass)
      attempt.end!
      expect(attempt.reload.status).to eq("ended")
      expect(attempt.finished_at).to be_nil
      expect(pass.reload.spent?).to be false
    end

    it "becomes unspent again when an operator reinstates the attempt" do
      attempt = attempt_for(pass)
      attempt.exit!
      expect(pass.reload.spent?).to be true

      attempt.reinstate!
      expect(pass.reload.spent?).to be false
    end

    it "becomes unspent again when an operator moves the team to a level" do
      attempt = attempt_for(pass)
      attempt.update!(:finished_at => Time.now)
      attempt.move_to_level!(level)
      expect(pass.reload.spent?).to be false
    end
  end

  describe "#live?" do
    it "is false once revoked, even with no attempt" do
      pass.update!(:revoked_at => Time.now)
      expect(pass.revoked?).to be true
      expect(pass.live?).to be false
    end
  end

  describe ".next_for" do
    it "is nil when the team holds none" do
      expect(AccessPass.next_for(game, team)).to be_nil
    end

    it "returns the only live pass" do
      expect(AccessPass.next_for(game, pass.team)).to eq(pass)
    end

    it "returns the OLDEST live pass when the team holds several" do
      older = pass
      newer = create_access_pass(:game => game, :team => team)
      newer.update_column(:created_at, older.created_at + 1.hour)

      expect(AccessPass.next_for(game, team)).to eq(older)
    end

    it "skips a spent pass and returns the next one" do
      spent = pass
      attempt_for(spent).update!(:finished_at => Time.now)
      nextone = create_access_pass(:game => game, :team => team)

      expect(AccessPass.next_for(game, team)).to eq(nextone)
    end

    it "skips a revoked pass" do
      pass.update!(:revoked_at => Time.now)
      expect(AccessPass.next_for(game, team)).to be_nil
    end

    it "does not return another game's pass" do
      other = create_level.game
      other.update!(:access_mode => "pass_required")
      create_access_pass(:game => other, :team => team)

      expect(AccessPass.next_for(game, team)).to be_nil
    end
  end
end
