require "rails_helper"

# The home page (IndexController#index) shows the games list inline instead
# of making a visitor click through to /games -- see games-list.feature:33,
# which still expects "Список игр" to be a clickable link on the home page,
# so IndexController must reuse GamesController#index's no-user_id scope
# (Game.visible), not Game.all, or a draft/withdrawn game would leak onto
# the very first page anyone sees.
describe "the home page games list", type: :request do
  it "shows a visible game's name without following any link" do
    game = create_game(:is_draft => false, :name => "Открытая игра", :max_team_number => 20)
    set_game_schedule!(game, :starts_at => 2.hours.ago)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Открытая игра")
  end

  it "does not show a draft game" do
    create_game(:is_draft => true, :name => "Черновик", :max_team_number => 20)

    get root_path

    expect(response.body).not_to include("Черновик")
  end

  it "does not show a withdrawn game" do
    game = create_game(:is_draft => false, :name => "Отозванная игра", :max_team_number => 20)
    set_game_schedule!(game, :starts_at => 2.hours.ago)
    game.withdraw!

    get root_path

    expect(response.body).not_to include("Отозванная игра")
  end
end
