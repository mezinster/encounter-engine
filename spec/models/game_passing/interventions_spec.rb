require "rails_helper"

describe GamePassing, "interventions" do
  let(:game)     { create_game }
  let(:first)    { create_level(:game => game) }
  let(:second)   { create_level(:game => game) }
  let(:passing)  { create_game_passing(:level => first) }

  describe "#move_to_level!" do
    it "puts the team on the level, with a fresh clock and no answers carried over" do
      passing.update!(:answered_questions => [ create_question(:level => first) ])
      passing.update_column(:current_level_entered_at, 3.hours.ago)

      passing.move_to_level!(second)

      passing.reload
      expect(passing.current_level).to eq(second)
      expect(passing.answered_questions).to be_empty
      expect(passing.current_level_entered_at).to be_within(5.seconds).of(Time.now)
    end

    # A team standing on a level is by definition not finished. Leaving
    # finished_at set on a team that is visibly mid-level is exactly the
    # contradictory row the whole design exists to prevent.
    it "un-finishes a team that had finished" do
      passing.update!(:finished_at => 1.hour.ago, :status => "ended")

      passing.move_to_level!(second)

      expect(passing.reload.finished_at).to be_nil
      expect(passing.status).to be_nil
    end

    it "un-exits a team that had quit" do
      passing.exit!

      passing.move_to_level!(second)

      expect(passing.reload.exited?).to be false
      expect(passing.finished_at).to be_nil
    end

    # Nothing else in the app would stop this, and the result is a passing
    # whose current_level belongs to a game it is not playing.
    it "refuses a level from another game" do
      other = create_level(:game => create_game)

      expect { passing.move_to_level!(other) }.to raise_error(ArgumentError)
      expect(passing.reload.current_level).to eq(first)
    end
  end

  describe "#reinstate!" do
    it "returns an exited team to play" do
      passing.exit!

      passing.reinstate!

      passing.reload
      expect(passing.exited?).to be false
      expect(passing.finished_at).to be_nil
      expect(passing.status).to be_nil
    end

    # exit! leaves current_level_entered_at untouched, so a team that quit an
    # hour ago carries an hour-old clock. Reinstating without the reset fires
    # every hint on that level the moment they reload -- a bigger unfairness
    # than the one the rescue was for.
    it "resets the level clock" do
      passing.update_column(:current_level_entered_at, 2.hours.ago)
      passing.exit!

      passing.reinstate!

      expect(passing.reload.current_level_entered_at).to be_within(5.seconds).of(Time.now)
    end
  end

  describe "#reset_level_clock!" do
    it "restarts the countdown" do
      passing.update_column(:current_level_entered_at, 90.minutes.ago)

      passing.reset_level_clock!

      expect(passing.reload.current_level_entered_at).to be_within(5.seconds).of(Time.now)
    end

    it "refuses a finished team, which has no live countdown" do
      passing.update!(:finished_at => Time.now)

      expect { passing.reset_level_clock! }.to raise_error(ArgumentError)
    end
  end
end
