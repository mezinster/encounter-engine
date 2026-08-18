require "rails_helper"

describe "standings on a gated game's page", type: :request do
  let(:level) { create_level }
  let(:game)  { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }

  it "renders the finishing team's result" do
    pass    = create_access_pass(:game => game)
    started = 3.days.ago
    attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                  :game_run => nil, :access_pass => pass)
    attempt.update_columns(:created_at => started, :finished_at => started + 600)

    get game_path(game)

    expect(response.body).to include("Результаты")
    expect(response.body).to include(pass.team.name)
  end

  it "does not render standings on a scheduled game's page" do
    scheduled = create_game(:is_draft => false, :access_mode => "scheduled")

    get game_path(scheduled)

    expect(response.body).not_to include("Результаты")
  end

  it "redirects the run-results page to the game page" do
    get game_passings_show_results_path(:game_id => game.id)

    expect(response).to redirect_to(game_path(game))
  end
end
