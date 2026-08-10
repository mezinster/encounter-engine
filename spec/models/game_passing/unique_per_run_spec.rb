# -*- encoding : utf-8 -*-
require "rails_helper"

# One passing per team per run. Until this index existed the invariant was
# enforced only by find_or_create_game_passing's read, so a double-submitted
# first request could create two.
RSpec.describe GamePassing, "one per team per run" do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  it "refuses a second passing for the same team in the same run" do
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)

    expect {
      GamePassing.create!(:game => game, :game_run => game.current_run,
                          :team => team, :current_level => level)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # The same team playing a LATER run is the whole point of the programme, so
  # the index must not stand in its way.
  it "allows the same team a passing in a different run" do
    create_game_passing(:level => level, :team => team, :game_run => game.current_run)
    second = create_next_run(game)

    expect {
      GamePassing.create!(:game => game, :game_run => second,
                          :team => team, :current_level => level)
    }.not_to raise_error
  end
end
