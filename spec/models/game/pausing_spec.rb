require "rails_helper"

describe Game, "pausing" do
  # starts_at in the past is what makes this a LIVE game -- and also what makes
  # it fail its own validations (game_starts_in_the_future), which is why
  # pause!/resume! must use update_column.
  let(:game)    { g = create_game; g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }

  it "starts unpaused" do
    expect(game.paused?).to be false
  end

  it "pauses and resumes" do
    game.pause!
    expect(game.reload.paused?).to be true

    game.resume!
    expect(game.reload.paused?).to be false
  end

  # The trap this whole design had to route around: a running game does not
  # pass its own validations, so update! would raise RecordInvalid on exactly
  # the games pause exists for, and update would fail silently.
  it "pauses a game whose start time is in the past" do
    expect(game.valid?).to be false

    expect { game.pause! }.not_to raise_error
    expect(game.reload.paused_at).not_to be_nil
  end

  it "refuses to pause twice, or to resume a game that is not paused" do
    expect { game.resume! }.to raise_error(ArgumentError)

    game.pause!
    expect { game.pause! }.to raise_error(ArgumentError)
  end

  describe "the countdown" do
    # The property the whole feature turns on: a team resumes with exactly the
    # countdown it had when play stopped.
    it "gives back the same remaining time after a pause" do
      passing.update_column(:current_level_entered_at, 10.minutes.ago)

      game.pause!
      paused_remaining = Time.now - passing.reload.current_level_entered_at

      travel_to(30.minutes.from_now) do
        game.reload.resume!
        resumed_remaining = Time.now - passing.reload.current_level_entered_at

        expect(resumed_remaining).to be_within(5.seconds).of(paused_remaining)
      end
    end

    it "leaves finished teams alone" do
      passing.update!(:finished_at => Time.now)
      entered_at = passing.reload.current_level_entered_at

      game.pause!
      travel_to(20.minutes.from_now) { game.reload.resume! }

      expect(passing.reload.current_level_entered_at).to eq(entered_at)
    end
  end

  describe "frozen hints" do
    # Not merely uncounted afterwards: level_hint_updater.js polls
    # get_current_level_tip throughout the pause, so a hint that becomes
    # visible DURING the hold has already been read by the time resume shifts
    # the clock back. This is the failure effective_now exists to prevent, and
    # it is invisible to any test that only inspects state after resuming.
    it "does not reveal a new hint while the game is paused" do
      create_hint(:level => level, :delay => 20 * 60)
      passing.update_column(:current_level_entered_at, 5.minutes.ago)

      expect(passing.reload.hints_to_show).to be_empty

      game.pause!

      travel_to(1.hour.from_now) do
        expect(passing.reload.hints_to_show).to be_empty
      end
    end

    it "reveals it normally when the game is not paused" do
      create_hint(:level => level, :delay => 20 * 60)
      passing.update_column(:current_level_entered_at, 5.minutes.ago)

      travel_to(1.hour.from_now) do
        expect(passing.reload.hints_to_show.size).to eq(1)
      end
    end
  end
end
