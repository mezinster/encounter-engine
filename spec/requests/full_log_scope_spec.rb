require "rails_helper"

# app/views/logs/show_full_log.html.erb builds
# `team_logs = Log.of_team(team).of_level(level)` -- neither of_team nor
# of_level filters by game, and logs.team/logs.level are name strings, not
# foreign keys (db/schema.rb:120-121), so this matches the named team's
# submissions at the named level across EVERY game the team ever played, not
# just the one being viewed. Worse than show_game_log's bug (Task 1): these
# rows print fully attributed, under the level's own heading and the team's
# own column, not as an unattributed pile.
describe "the full answer log", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }
  let!(:level) { create_level(:game => game, :name => "Уровень 1") }
  let(:team)   { create_team(:captain => create_user) }

  let(:other_game)   { create_game(:author => create_user) }
  let!(:other_level) { create_level(:game => other_game, :name => "Уровень 1") }

  before do
    # Puts `team` on @teams for `game`'s full log -- LogsController#show_full_log
    # builds @teams by joining teams to game_passings on the viewed game's id.
    create_game_passing(:team => team, :level => level)
    put login_path, :params => { :email => author.email, :password => "1234" }
  end

  it "does not show a colliding-named level's log from a different game the team played" do
    # Sanity guard, same spirit as Task 1's: if these two ever collided the
    # example below would be meaningless rather than red.
    expect(game.id).not_to eq(other_game.id)

    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "СВОЙ-КОД")
    Log.create!(:game_id => other_game.id, :level => other_level.name, :level_id => other_level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "ЧУЖАЯ-ИГРА")

    get show_full_log_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("СВОЙ-КОД")
    expect(response.body).not_to include("ЧУЖАЯ-ИГРА")
  end

  # Same-game name collision: two levels sharing a name is the case
  # of_level's id fallback exists for -- Log.backfill_ids! calls a level name
  # "ambiguous" precisely when Level.where(game_id:, name:) resolves more than
  # one row (see app/models/log.rb). A name-only scope cannot tell these two
  # rows' levels apart; an id-scoped one can. show_full_log prints one row per
  # (level, team) heading, so a name collision would print the same answer
  # twice -- once under each level's heading -- under the old scope.
  it "does not show a level's rows under a same-named level's heading in the same game" do
    other_level_same_game = create_level(:game => game, :name => level.name)

    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "ОДНОЗНАЧНЫЙ-КОД")

    get show_full_log_path(:game_id => game.id)

    expect(response.body.scan("ОДНОЗНАЧНЫЙ-КОД").length).to eq(1)
  end

  # The example above ("colliding-named level ... different game") passes
  # even with of_game dropped from the controller, because the other game's
  # log row points at other_level -- a different id from `level` -- so
  # of_level(level) alone already excludes it. That makes of_game look
  # unpinned: it isn't. Here the row's level_id/team_id genuinely match
  # `level`/`team` in `game` (of_level and of_team alone would let it
  # through); only its own :game_id column says otherwise (data corruption,
  # or a future write path that gets it wrong). of_game is the only scope
  # that can catch this one.
  it "does not show a row whose game_id disagrees with its own (correct) level_id and team_id" do
    expect(game.id).not_to eq(other_game.id)

    Log.create!(:game_id => other_game.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "НЕВЕРНЫЙ-GAME-ID")

    get show_full_log_path(:game_id => game.id)

    expect(response.body).not_to include("НЕВЕРНЫЙ-GAME-ID")
  end

  # LogsController#show_full_log builds @teams with
  # Team.find_by_sql("select * from teams t inner join game_passings gp
  # on t.id = gp.team_id where gp.game_id = ..."). A bare `select *` across
  # that join returns `id` twice -- teams.id, then game_passings.id -- and
  # the later column wins, so every row in @teams actually carries the
  # game_passing's id, not the team's. `name` survives only because
  # game_passings has no name column.
  #
  # Under transactional rollback both tables' AUTOINCREMENT counters restart
  # together, so when N teams and N game_passings are created in the same
  # relative order (as every other example in this file does), gp.id == team.id
  # by coincidence -- which is exactly why nothing else here can see this bug.
  # This example burns extra game_passing ids first so they can't align.
  it "attributes rows to the right team's column even when game_passing ids don't align with team ids" do
    burner_team = create_team(:captain => create_user)
    3.times { create_game_passing(:team => burner_team, :level => create_level(:game => create_game)) }

    team_one = create_team(:captain => create_user)
    team_two = create_team(:captain => create_user)
    create_game_passing(:team => team_one, :level => level)
    create_game_passing(:team => team_two, :level => level)

    # Sanity guard, same spirit as the other examples in this file: if these
    # ever coincide the assertions below would be meaningless rather than red.
    expect(GamePassing.of(team_one, game).id).not_to eq(team_one.id)
    expect(GamePassing.of(team_two, game).id).not_to eq(team_two.id)

    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team_one.name, :team_id => team_one.id,
                :time => Time.now, :answer => "КОД-ОДИН")
    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team_two.name, :team_id => team_two.id,
                :time => Time.now, :answer => "КОД-ДВА")

    get show_full_log_path(:game_id => game.id)

    doc = Nokogiri::HTML(response.body)
    cells = doc.css("table#stats td")
    team_one_cell = cells.find { |td| td.text.include?(team_one.name) }
    team_two_cell = cells.find { |td| td.text.include?(team_two.name) }

    expect(team_one_cell.text).to include("КОД-ОДИН")
    expect(team_one_cell.text).not_to include("КОД-ДВА")
    expect(team_two_cell.text).to include("КОД-ДВА")
    expect(team_two_cell.text).not_to include("КОД-ОДИН")
  end
end
