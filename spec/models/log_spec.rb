require "rails_helper"

# logs.team and logs.level are name strings, which is why every scope except
# of_game was globally ambiguous and produced two cross-game disclosures. The
# ids are additive: the strings stay as the historical snapshot and as what the
# live channel renders.
describe Log do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  it "carries both the id and the name for a level" do
    log = Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                      :team => team.name, :team_id => team.id,
                      :time => Time.now, :answer => "код")

    expect(log.reload.level_id).to eq(level.id)
    expect(log.level).to eq(level.name)
    expect(log.level_record).to eq(level)
    expect(log.team_record).to eq(team)
  end

  it "tolerates a row whose ids were never backfilled" do
    log = Log.create!(:game_id => game.id, :level => "Старое задание",
                      :team => "Старая команда", :time => Time.now, :answer => "код")

    expect(log.reload.level_record).to be_nil
    expect(log.team_record).to be_nil
    expect(log.level).to eq("Старое задание")
  end

  # Task 4: of_team/of_level dropped the name-based fallback once production
  # confirmed nothing depended on it (see app/models/log.rb). A row whose
  # id was never backfilled now simply does not match -- it used to be
  # picked up by "logs.team_id IS NULL AND logs.team = :name". Assert that
  # explicitly rather than leaving it as an emergent property of the scope.
  it "does not return a row whose id was never backfilled, even though its name matches" do
    log = Log.create!(:game_id => game.id, :level => level.name,
                      :team => team.name, :time => Time.now, :answer => "код")

    expect(Log.of_team(team)).not_to include(log)
    expect(Log.of_level(level)).not_to include(log)
  end
end
