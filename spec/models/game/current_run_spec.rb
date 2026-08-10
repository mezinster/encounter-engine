# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe Game, "#current_run" do
  it "autobuilds a first run for a game that has none" do
    game = create_game
    game.runs.delete_all
    game.reload

    expect(game.current_run).to be_a(GameRun)
    expect(game.current_run.ordinal).to eq(1)
  end

  # THE hazard. runs.last on an unloaded association issues
  # SELECT ... ORDER BY ordinal DESC LIMIT 1, which cannot see a record that
  # only exists in memory -- so a second call would build a SECOND run, and
  # autosave would persist both. runs.to_a calls load_target, which merges
  # unsaved records into the loaded target.
  #
  # create_game passes both :starts_at and :max_team_number, so once Task 3
  # delegates, every fixture in the suite goes through this path twice.
  it "returns the same run when asked twice" do
    game = create_game
    game.runs.delete_all
    game.reload

    expect(game.current_run).to equal(game.current_run)
  end

  it "builds only one run however many times it is asked" do
    game = create_game
    game.runs.delete_all
    game.reload

    3.times { game.current_run }
    # Deleting the run took the schedule with it, so the game is momentarily
    # invalid (max_team_number is nil, and valid_max_num requires 1..9999).
    # Restoring it is arranging the example, not part of what is under test.
    game.max_team_number = 100
    game.save!

    expect(game.runs.reload.size).to eq(1)
  end

  it "returns the highest ordinal when several runs exist" do
    game = create_game
    game.runs.delete_all
    GameRun.create!(:game => game, :ordinal => 1)
    second = GameRun.create!(:game => game, :ordinal => 2)
    game.reload

    expect(game.current_run).to eq(second)
  end

  # has_many saves NEW children on parent save by default but does NOT save
  # CHANGED persisted ones -- which would break the edit form the moment Task 3
  # delegates. autosave: true is what makes `game.save` persist a modified run.
  it "saves a changed run when the game is saved" do
    game = create_game
    game.current_run.max_team_number = 77
    game.save!

    expect(game.runs.reload.last.max_team_number).to eq(77)
  end

  # The run is arranged explicitly rather than relying on create_game, which
  # only starts building one once the delegation lands. Deterministic on both
  # sides of that change.
  it "destroys its runs with the game" do
    game = create_game
    game.runs.delete_all
    GameRun.create!(:game => game, :ordinal => 1)

    expect { game.reload.destroy }.to change(GameRun, :count).by(-1)
  end
end
