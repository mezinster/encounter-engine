# -*- encoding : utf-8 -*-
require "rails_helper"

# A log states its run as a fact rather than inferring it from the team's
# passing. The inference is unambiguous only while a game has one run, and
# phase 3 is exactly when it stops being.
RSpec.describe Log, ".backfill_run_ids!" do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  def bare_log
    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "код")
  end

  it "resolves a log to its game's run" do
    log = bare_log
    log.update_column(:game_run_id, nil)

    expect { Log.backfill_run_ids! }
      .to change { log.reload.game_run_id }.from(nil).to(game.current_run.id)
  end

  it "reports how many it resolved" do
    log = bare_log
    log.update_column(:game_run_id, nil)

    expect(Log.backfill_run_ids!).to eq(:resolved => 1)
  end

  # Idempotent: a silent backfill that resolved nothing must not look
  # identical to one that resolved everything -- the reason backfill_ids!
  # returns counts too.
  it "resolves nothing on a second run and says so" do
    bare_log
    Log.backfill_run_ids!

    expect(Log.backfill_run_ids!).to eq(:resolved => 0)
  end

  it "leaves a log with no game alone" do
    orphan = Log.create!(:game_id => nil, :level => "x", :team => "y",
                         :time => Time.now, :answer => "z")
    orphan.update_column(:game_run_id, nil)

    Log.backfill_run_ids!

    expect(orphan.reload.game_run_id).to be_nil
  end

  # run_one is captured BEFORE the second run is created: create_next_run gives
  # the game a higher ordinal, so current_run then answers with the new run.
  it "scopes logs to a run" do
    run_one = game.current_run
    mine = Log.create!(:game_id => game.id, :game_run_id => run_one.id,
                       :level => level.name, :level_id => level.id,
                       :team => team.name, :team_id => team.id,
                       :time => Time.now, :answer => "мой")
    other_run = create_next_run(game)
    Log.create!(:game_id => game.id, :game_run_id => other_run.id,
                :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "другой")

    expect(Log.of_run(run_one).map(&:id)).to eq([ mine.id ])
    expect(Log.of_run(other_run).map(&:answer)).to eq([ "другой" ])
  end
end
