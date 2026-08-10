# -*- encoding : utf-8 -*-
require "rails_helper"

# The single writer that creates a run, mirroring transfer_authorship_to!.
# See docs/superpowers/specs/2026-08-10-game-runs-phase-3-design.md.
RSpec.describe Game, "#open_run!" do
  let(:game) { create_game }

  def valid_attrs(overrides = {})
    { :starts_at => 2.years.from_now,
      :registration_deadline => 23.months.from_now,
      :max_team_number => 10 }.merge(overrides)
  end

  it "creates the next ordinal" do
    run = game.open_run!(valid_attrs)

    expect(run.ordinal).to eq(2)
    expect(game.runs.reload.map(&:ordinal)).to eq([ 1, 2 ])
  end

  it "makes the new run the current one" do
    run = game.open_run!(valid_attrs)

    expect(game.reload.current_run).to eq(run)
  end

  it "carries the schedule it was given" do
    run = game.open_run!(valid_attrs(:max_team_number => 42))

    expect(run.max_team_number).to eq(42)
  end

  # Capacity is per run from phase 1, so a new run starts empty however full
  # the previous one was.
  it "starts with an empty team counter" do
    game.current_run.update_column(:requested_teams_number, 7)

    expect(game.open_run!(valid_attrs).requested_teams_number).to eq(0)
  end

  it "leaves the previous run untouched" do
    first = game.current_run
    before = first.attributes

    game.open_run!(valid_attrs)

    expect(first.reload.attributes).to eq(before)
  end

  # Validated in the :open context, so these hold an operator opening a run
  # without ever firing on a run that merely exists with a past date -- which
  # is what every finished run is, and what a spec modelling an earlier cohort
  # has to be able to build.
  describe "validation, when opening" do
    it "allows a run with a past start date to exist outside that context" do
      run = game.runs.build(valid_attrs(:starts_at => 1.hour.ago).merge(:ordinal => 2))

      expect(run).to be_valid
    end

    it "refuses a start time in the past" do
      run = game.runs.build(valid_attrs(:starts_at => 1.hour.ago).merge(:ordinal => 2))

      expect(run).not_to be_valid(:open)
      expect(run.errors[:starts_at]).not_to be_empty
    end

    it "refuses a registration deadline after the start" do
      run = game.runs.build(valid_attrs(:registration_deadline => 3.years.from_now).merge(:ordinal => 2))

      expect(run).not_to be_valid(:open)
      expect(run.errors[:registration_deadline]).not_to be_empty
    end

    it "refuses a missing team cap" do
      run = game.runs.build(valid_attrs(:max_team_number => nil).merge(:ordinal => 2))

      expect(run).not_to be_valid(:open)
      expect(run.errors[:max_team_number]).not_to be_empty
    end

    # THE trap. Game has autosave: true on :runs, and finish_game! saves a game
    # whose starts_at is long past. An unconditional validation here would
    # raise on exactly the games that method exists for -- which is why phase 1
    # (D4) left these on Game in the first place.
    it "does not re-validate an existing run when its game is saved" do
      running = create_game(:is_draft => false)
      set_game_schedule!(running, :starts_at => 1.hour.ago)

      expect { running.finish_game! }.not_to raise_error
      expect(running.reload).to be_author_finished
    end

    it "does not block an ordinary save of a game whose run is long past" do
      running = create_game(:is_draft => false)
      set_game_schedule!(running, :starts_at => 1.hour.ago, :author_finished_at => Time.now)

      expect { running.reload.save! }.not_to raise_error
    end
  end
end
