require "rails_helper"

# app/views/logs/show_game_log.html.erb passed a Level to Log.of_game, whose
# scope is where(game_id: game) -- Rails resolves an AR object by #id, so a
# Level resolved to where(game_id: <level.id>), rendering the log of whatever
# GAME shared that integer, unfiltered by team.
describe "the per-game answer log", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.update_column(:starts_at, 1.hour.ago)
    g
  end
  let(:team) { create_team(:captain => create_user) }

  # Both the games and levels tables start each example with a freshly rolled
  # back AUTOINCREMENT counter (see features/support/env.rb's sibling comment
  # on the Cucumber side), so the first game and the first level created in an
  # example both land on id 1 -- exactly the collision the second example
  # below needs to NOT have, or it would pass for the wrong reason. This
  # throwaway game advances the games counter before `game`/`level` exist, so
  # `game.id` (2) and `level.id` (1) are guaranteed distinct.
  before { create_game(:author => create_user, :is_draft => false) }

  let!(:level) { create_level(:game => game) }

  before do
    put login_path, :params => { :email => author.email, :password => "1234" }
  end

  it "shows this team's submissions on this game" do
    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "МОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("МОЙ-КОД")
  end

  it "does not show submissions whose game id merely equals a level id" do
    # If this ever fails, the throwaway game above stopped doing its job and
    # the example below would pass vacuously -- fail loudly instead.
    expect(game.id).not_to eq(level.id)

    Log.create!(:game_id => level.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "ЧУЖОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖОЙ-КОД")
  end

  it "does not show another team's submissions on this game" do
    other = create_team(:captain => create_user)
    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => other.name, :team_id => other.id,
                :time => Time.now, :answer => "ЧУЖАЯ-КОМАНДА")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖАЯ-КОМАНДА")
  end

  # of_game excludes this row on game id alone, before name ever enters into
  # it -- the level and its name are identical to the ones in `game`, only
  # the owning game differs. Pins that of_game does not accidentally admit a
  # row via a name/level match once the game itself is wrong.
  it "does not show a same-named level's rows from another game" do
    other_game  = create_game
    other_level = create_level(:game => other_game, :name => level.name)
    Log.create!(:game_id => other_game.id, :level => other_level.name,
                :level_id => other_level.id, :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "ЧУЖОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖОЙ-КОД")
  end

end

# find_level (LogsController#find_level) resolves via Team#current_level_in,
# which is nil once GamePassing#pass_level! finishes a team's game -- reachable
# only by a finished team hitting show_level_log's URL directly (no UI link
# does it). See LogsController#show_level_log for the guard this proves.
describe "show_level_log for a team with no current level", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.update_column(:starts_at, 1.hour.ago)
    g
  end
  let!(:level) { create_level(:game => game) }
  let(:team)   { create_team(:captain => create_user) }

  before do
    passing = create_game_passing(:team => team, :level => level)
    passing.pass_level! # level.next is nil -- this finishes the team and nils current_level

    put login_path, :params => { :email => author.email, :password => "1234" }
  end

  it "renders an empty log instead of 500ing or matching every unresolved row" do
    Log.create!(:game_id => game.id, :level => level.name, :level_id => level.id,
                :team => team.name, :team_id => team.id,
                :time => Time.now, :answer => "НЕ-ДОЛЖЕН-ПОПАСТЬ")

    get show_level_log_path(:game_id => game.id, :team_id => team.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("НЕ-ДОЛЖЕН-ПОПАСТЬ")
  end
end
