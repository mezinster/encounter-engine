require "rails_helper"

# The column used to render game_passings.size alone, which counts only teams
# that have ENTERED the game. A draft or scheduled game with confirmed
# registrations therefore showed 0 -- reported from production by an operator
# who had a team signed up and saw nothing.
describe "the admin console's team counts", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  before { put login_path, :params => { :email => superadmin.email, :password => "1234" } }

  # create_game_entry, not a bare GameEntry.create!, because that left
  # game_run_id NULL -- a state the application cannot produce (the one
  # creation path, GameEntriesController#new, always passes
  # game_run: @game.current_run, and CreateGameRuns backfilled every existing
  # row) and one that authorises nothing, since every admission check reads
  # GameEntry.of_run. The counts these examples assert are run-scoped now, so
  # a runless entry is invisible to them -- correctly.
  def register(game, status = "accepted")
    create_game_entry(:game => game, :team => create_team(:captain => create_user), :status => status)
  end

  it "counts a registration on a DRAFT game, which used to render 0" do
    game = create_game(:author => author, :is_draft => true, :max_team_number => 20)
    register(game)

    get admin_games_path

    expect(response.body).to include("1 / 20")
  end

  it "counts a registration on a scheduled game" do
    game = create_game(:author => author, :is_draft => false, :max_team_number => 20)
    register(game)

    get admin_games_path

    expect(response.body).to include("1 / 20")
  end

  it "counts only accepted registrations" do
    game = create_game(:author => author, :is_draft => false, :max_team_number => 20)
    register(game, "accepted")
    register(game, "new")
    register(game, "rejected")

    get admin_games_path

    expect(response.body).to include("1 / 20")
  end

  it "also reports teams actually playing once the game is running" do
    game = create_game(:author => author, :is_draft => false, :max_team_number => 20)
    register(game)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    create_game_passing(:level => create_level(:game => game), :game => game)

    get admin_games_path

    expect(response.body).to include(I18n.t("games.list.playing", :count => 1))
  end

  it "shows no playing figure for a game nobody has entered" do
    game = create_game(:author => author, :is_draft => true, :max_team_number => 20)
    register(game)

    get admin_games_path

    expect(response.body).not_to include(I18n.t("games.list.playing", :count => 1))
  end
end
