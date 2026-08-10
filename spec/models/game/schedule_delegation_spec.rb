# -*- encoding : utf-8 -*-
require "rails_helper"

# The schedule lives on the run; Game delegates. Phase 1's whole claim is that
# this changes nothing, so these examples check the paths the rest of the suite
# and the frozen scenarios actually drive.
RSpec.describe Game, "schedule delegation" do
  it "lands an attribute passed to new on the autobuilt run" do
    game = Game.new(:starts_at => Time.utc(2040, 1, 1, 12, 0))

    expect(game.current_run.starts_at).to eq(Time.utc(2040, 1, 1, 12, 0))
  end

  # create_game passes BOTH, which is what makes the runs.to_a.last hazard
  # reachable from every fixture in the suite.
  it "builds exactly one run for a game given several schedule attributes" do
    game = create_game(:starts_at => "2099-01-01 00:00", :max_team_number => 10)

    expect(game.runs.reload.size).to eq(1)
    expect(game.max_team_number).to eq(10)
  end

  it "persists a schedule change made through the game" do
    game = create_game
    game.max_team_number = 55
    game.save!

    expect(game.reload.max_team_number).to eq(55)
    expect(game.runs.reload.last.max_team_number).to eq(55)
  end

  it "reads back what the run holds" do
    game = create_game
    game.current_run.update_column(:starts_at, Time.utc(2045, 3, 3))

    expect(game.reload.starts_at).to eq(Time.utc(2045, 3, 3))
  end

  # D4: the four schedule validations stay on Game and read the delegated
  # values. If the delegation ever returns a stale games column, these pass
  # while validating the wrong number -- so they are asserted explicitly rather
  # than assumed from the suite staying green.
  describe "the validations that stayed on Game" do
    it "still rejects a start time in the past" do
      game = build_game(:starts_at => 1.hour.ago)

      expect(game).not_to be_valid
      expect(game.errors[:starts_at]).not_to be_empty
    end

    it "still rejects a registration deadline after the start" do
      game = build_game(:starts_at => "2099-01-01 00:00",
                        :registration_deadline => "2099-02-01 00:00")

      expect(game).not_to be_valid
      expect(game.errors[:registration_deadline]).not_to be_empty
    end

    it "still rejects a team cap below the number already registered" do
      game = create_game(:max_team_number => 5)
      set_game_schedule!(game, :requested_teams_number => 4)
      game.reload.max_team_number = 3

      expect(game).not_to be_valid
      expect(game.errors[:max_team_number]).not_to be_empty
    end

    # The error must still land on the FIELD, not on :base. Moving the
    # validations to GameRun and promoting them up would put them on :base --
    # which is exactly what D4 defers to phase 3 to avoid.
    it "puts the error on the field rather than on base" do
      game = build_game(:starts_at => 1.hour.ago)
      game.valid?

      expect(game.errors[:base]).to be_empty
    end
  end

  describe "the lifecycle writers" do
    # A started game fails its own validations, which is why these use
    # update_column. create_game defaults starts_at to 2099, so a spec that
    # does not arrange a started game proves nothing about the case these
    # methods exist for.
    def running_game
      game = create_game(:is_draft => false)
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      game
    end

    it "pauses onto the run" do
      game = running_game
      game.pause!

      expect(game.runs.reload.last.paused_at).to be_present
      expect(game.reload).to be_paused
    end

    it "resumes off the run" do
      game = running_game
      game.pause!
      game.resume!

      expect(game.runs.reload.last.paused_at).to be_nil
      expect(game.reload).not_to be_paused
    end

    it "finishes onto the run" do
      game = running_game
      game.finish_game!

      expect(game.runs.reload.last.author_finished_at).to be_present
      expect(game.reload).to be_author_finished
    end

    it "unfinishes off the run" do
      game = running_game
      game.finish_game!
      game.unfinish!

      expect(game.runs.reload.last.author_finished_at).to be_nil
      expect(game.reload).not_to be_author_finished
    end

    it "counts a reserved place onto the run" do
      game = create_game(:max_team_number => 5)
      game.reserve_place_for_team!

      expect(game.runs.reload.last.requested_teams_number).to eq(1)
      expect(game.reload.requested_teams_number).to eq(1)
    end

    it "frees a place off the run" do
      game = create_game(:max_team_number => 5)
      game.reserve_place_for_team!
      game.free_place_of_team!

      expect(game.runs.reload.last.requested_teams_number).to eq(0)
    end
  end
end
