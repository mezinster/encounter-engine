require "rails_helper"

# Team names are globally unique in practice (validated, and Team has no rename
# or destroy path), so those resolve. Level names are NOT unique within a game
# -- Level validates presence only -- so an ambiguous name must be left NULL
# rather than guessed at.
describe "backfilling log ids", type: :request do
  let(:game) { create_game }

  it "resolves an unambiguous level name within its own game" do
    level = create_level(:game => game, :name => "Уникальное задание")
    team  = create_team(:captain => create_user)
    log   = Log.create!(:game_id => game.id, :level => level.name,
                        :team => team.name, :time => Time.now, :answer => "код")

    Log.backfill_ids!

    expect(log.reload.level_id).to eq(level.id)
    expect(log.team_id).to eq(team.id)
  end

  it "leaves a level name that is ambiguous within its game NULL" do
    first  = create_level(:game => game, :name => "Одинаковое")
    create_level(:game => game, :name => "Одинаковое")
    team   = create_team(:captain => create_user)
    log    = Log.create!(:game_id => game.id, :level => "Одинаковое",
                         :team => team.name, :time => Time.now, :answer => "код")

    Log.backfill_ids!

    expect(log.reload.level_id).to be_nil
    expect(log.team_id).to eq(team.id)
    expect(first).to be_present
  end

  it "does not match a level of the same name in a different game" do
    other_level = create_level(:name => "Общее имя")
    log = Log.create!(:game_id => game.id, :level => "Общее имя",
                      :team => "Нет такой команды", :time => Time.now, :answer => "код")

    Log.backfill_ids!

    expect(log.reload.level_id).to be_nil
    expect(other_level.game_id).not_to eq(game.id)
  end
end
