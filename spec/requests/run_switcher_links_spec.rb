# -*- encoding : utf-8 -*-
require "rails_helper"

# The switcher must only link runs whose results can actually be shown.
#
# It listed every run unconditionally, so a scheduled rerun appeared as a link
# that answered 401 -- ensure_game_is_started judges the run being viewed, and
# a run that has not started cannot be viewed. Found on production the day
# «Викторина» got its second run.
#
# The rule now has ONE definition, GameRun#results_visible?, which the guard
# and the view both read. Two encodings of the same rule is what let them
# disagree in the first place.
describe "the run switcher's links", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  def open_future_run
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
  end

  def switcher
    get game_passings_show_results_path(:game_id => game.id)
    Capybara.string(response.body)
  end

  def label_for(ordinal, date)
    I18n.t("shared.run_switcher.run_label", :ordinal => ordinal, :date => date)
  end

  it "still names a run that has not started" do
    open_future_run

    expect(switcher.text).to include("Забег №2")
  end

  it "does not link a run that has not started" do
    open_future_run

    expect(switcher).to have_no_link(:href => %r{run=2})
  end

  # The regression guard: following such a link is refused, which is why it
  # must not be offered.
  it "refuses that run's results if the URL is reached anyway" do
    open_future_run

    get game_passings_show_results_path(:game_id => game.id, :run => 2)

    expect(response).to have_http_status(:unauthorized)
  end

  it "links an earlier run that has started" do
    open_future_run
    # Bring run 2 into the present so run 1 becomes the linkable one.
    set_game_schedule!(game, :starts_at => 1.hour.ago)

    expect(switcher).to have_link(:href => %r{run=1})
  end

  it "does not link the run already being shown" do
    open_future_run
    set_game_schedule!(game, :starts_at => 1.hour.ago)

    # Run 2 is current and started, so it is the default and renders plain.
    expect(switcher).to have_no_link(:href => %r{run=2})
  end

  it "renders no switcher at all for a game with one run" do
    expect(switcher.text).not_to include(I18n.t("shared.run_switcher.heading"))
  end
end

RSpec.describe GameRun, "#results_visible?" do
  let(:game) { create_game(:is_draft => false) }

  it "is false before the run starts" do
    run = game.current_run
    run.update_column(:starts_at, 1.hour.from_now)

    expect(run.reload.results_visible?).to be false
  end

  it "is true once it has started" do
    run = game.current_run
    run.update_column(:starts_at, 1.hour.ago)

    expect(run.reload.results_visible?).to be true
  end

  it "is false with no start date at all" do
    run = game.current_run
    run.update_column(:starts_at, nil)

    expect(run.reload.results_visible?).to be false
  end

  # A draft is unpublished, so it has not begun whatever the clock says --
  # the same rule Game#started? applies.
  it "is false for a draft, whatever the clock says" do
    draft = create_game(:is_draft => true)
    draft.current_run.update_column(:starts_at, 1.hour.ago)

    expect(draft.current_run.reload.results_visible?).to be false
  end
end
