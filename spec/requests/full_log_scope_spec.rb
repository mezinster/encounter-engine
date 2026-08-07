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

    Log.create!(:game_id => game.id, :level => level.name, :team => team.name,
                :time => Time.now, :answer => "СВОЙ-КОД")
    Log.create!(:game_id => other_game.id, :level => other_level.name, :team => team.name,
                :time => Time.now, :answer => "ЧУЖАЯ-ИГРА")

    get show_full_log_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("СВОЙ-КОД")
    expect(response.body).not_to include("ЧУЖАЯ-ИГРА")
  end
end
