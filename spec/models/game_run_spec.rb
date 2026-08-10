# -*- encoding : utf-8 -*-
require "rails_helper"

# One running of a game. Phase 1 only creates these by backfill and by Game's
# autobuild; nothing yet reads them. See
# docs/superpowers/specs/2026-08-10-game-runs-phase-1-design.md.
RSpec.describe GameRun do
  let(:game) { create_game }

  # create_game builds run 1 through Game's delegated writers, so every game
  # arrives here with one already. These examples work with that rather than
  # against it.
  it "belongs to a game" do
    run = GameRun.create!(:game => game, :ordinal => 2)

    expect(run.game).to eq(game)
  end

  it "refuses a run with no game" do
    expect(GameRun.new(:ordinal => 1)).not_to be_valid
  end

  it "refuses a second run with the same ordinal in one game" do
    expect(game.runs.size).to eq(1)

    expect(GameRun.new(:game => game, :ordinal => 1)).not_to be_valid
  end

  # Ordinals are per game, not global -- two different games each have a run 1.
  it "allows the same ordinal in a different game" do
    other = create_game
    other.runs.delete_all

    expect(GameRun.new(:game => other, :ordinal => 1)).to be_valid
  end

  it "refuses a non-positive ordinal" do
    expect(GameRun.new(:game => game, :ordinal => 0)).not_to be_valid
  end
end
