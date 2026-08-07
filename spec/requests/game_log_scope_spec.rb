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
    Log.create!(:game_id => game.id, :level => level.name, :team => team.name,
                :time => Time.now, :answer => "МОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("МОЙ-КОД")
  end

  it "does not show submissions whose game id merely equals a level id" do
    # If this ever fails, the throwaway game above stopped doing its job and
    # the example below would pass vacuously -- fail loudly instead.
    expect(game.id).not_to eq(level.id)

    Log.create!(:game_id => level.id, :level => level.name, :team => team.name,
                :time => Time.now, :answer => "ЧУЖОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖОЙ-КОД")
  end

  it "does not show another team's submissions on this game" do
    other = create_team(:captain => create_user)
    Log.create!(:game_id => game.id, :level => level.name, :team => other.name,
                :time => Time.now, :answer => "ЧУЖАЯ-КОМАНДА")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖАЯ-КОМАНДА")
  end
end
