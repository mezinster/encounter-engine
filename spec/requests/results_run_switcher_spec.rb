# -*- encoding : utf-8 -*-
require "rails_helper"

# Opening a run must not make the previous run's standings unreachable -- that
# is the history this whole programme exists to preserve.
describe "the results page across runs", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end
  let(:level) { game.levels.first }

  def finished_team(run, finished_at)
    team = create_team(:captain => create_user)
    passing = create_game_passing(:level => level, :team => team, :game_run => run)
    passing.update_column(:finished_at, finished_at)
    team
  end

  def open_second_run
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
  end

  # A run can only be opened with a FUTURE start date, so it is always
  # unstarted at first. Bringing it into the present is what a spec has to do
  # to model the day it actually runs.
  def start_the_current_run
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game.reload
  end

  it "shows the latest started run by default" do
    old_team = finished_team(game.current_run, 2.days.ago)
    open_second_run
    start_the_current_run
    new_team = finished_team(game.current_run, 30.minutes.ago)

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).to include(new_team.name)
    expect(response.body).not_to include(old_team.name)
  end

  # THE case right after an operator schedules a rerun. Defaulting to the
  # current run would answer "the game has not started yet" and hide the
  # standings of the run that just finished -- from the page whose whole job
  # is to show them.
  it "still shows the finished run when the newly opened one has not started" do
    old_team = finished_team(game.current_run, 2.days.ago)
    open_second_run

    get game_passings_show_results_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(old_team.name)
  end

  # THE point of the phase: run 1's frozen table stays readable.
  it "shows an earlier run when asked for it by ordinal" do
    old_team = finished_team(game.current_run, 2.days.ago)
    open_second_run
    new_team = finished_team(game.current_run, 1.hour.ago)

    get game_passings_show_results_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(old_team.name)
    expect(response.body).not_to include(new_team.name)
  end

  it "falls back to the default run for an unknown ordinal" do
    finished_team(game.current_run, 2.days.ago)
    open_second_run
    start_the_current_run
    new_team = finished_team(game.current_run, 30.minutes.ago)

    get game_passings_show_results_path(:game_id => game.id, :run => 99)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(new_team.name)
  end

  it "falls back to the default run for a malformed ordinal" do
    finished_team(game.current_run, 2.days.ago)
    open_second_run
    start_the_current_run
    new_team = finished_team(game.current_run, 30.minutes.ago)

    get game_passings_show_results_path(:game_id => game.id, :run => "не-число")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(new_team.name)
  end

  it "ranks within the run being shown" do
    first  = finished_team(game.current_run, 3.days.ago)
    second = finished_team(game.current_run, 2.days.ago)
    open_second_run

    get game_passings_show_results_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(first.name)
    expect(response.body).to include(second.name)
  end

  # The href is compared HTML-escaped: the path carries an & between its two
  # query parameters, which ERB renders as &amp;, so a raw path would never
  # match and the example would fail whatever the view did.
  #
  # The link is to run 2, not run 1: run 1 is the default here (run 2 has not
  # started), and the selected run renders as plain text rather than a link.
  it "offers a switcher once a second run exists" do
    finished_team(game.current_run, 2.days.ago)
    open_second_run

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).to include(I18n.t("game_passings.show_results.runs_heading"))
    expect(response.body).to include(
      ERB::Util.html_escape(game_passings_show_results_path(:game_id => game.id, :run => 2))
    )
  end

  # THE frozen-scenario guard. Today's page must be byte-identical for the only
  # shape production has: one run.
  it "renders no switcher at all for a game with one run" do
    finished_team(game.current_run, 2.days.ago)

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).not_to include(I18n.t("game_passings.show_results.runs_heading"))
    expect(response.body).not_to include(
      ERB::Util.html_escape(game_passings_show_results_path(:game_id => game.id, :run => 1))
    )
  end
end
