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
    # Finding 5: the standings are RANKED by duration, so the column must show
    # it exactly (00:10:00 for 600 seconds) rather than
    # distance_of_time_in_words' nearest-few-minutes bucketing, which renders
    # the same "около Х минут"/"около Х часов" text for attempts many minutes
    # apart -- a table sorted by the very thing the reader cannot distinguish.
    expect(response.body).to include(attempt.seconds_to_hms(attempt.duration))
    expect(response.body).to include("00:10:00")
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
