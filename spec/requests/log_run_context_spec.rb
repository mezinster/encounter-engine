# -*- encoding : utf-8 -*-
require "rails_helper"

# The four log screens each show answers from exactly one run of one game and
# said almost nothing about which. The full log was the only one whose title
# named no subject at all, and none of the four named its run -- despite all
# four accepting ?run= with no UI that produces such a URL.
describe "the log screens' run context", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false, :name => "Викторина")
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end
  let(:level) { create_level(:game => game) }
  let(:team)  { create_team(:captain => create_user) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def play(run)
    create_game_passing(:level => level, :team => team, :game_run => run)
    create_log(:game => game, :level => level, :team => team,
               :game_run => run, :answer => "код")
  end

  def open_second_run
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game.reload
  end

  before { play(game.current_run) }

  # The frozen phrase must survive contiguously: five scenarios assert
  # "Полный лог ответов" through have_text(:all, ...), a whitespace-normalised
  # substring match. The game name goes AFTER it, never inside it.
  it "names the game in the full log's title, keeping the frozen phrase intact" do
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include("Полный лог ответов")
    expect(response.body).to include("Викторина")
  end

  it "names the run and its date on every log screen" do
    sign_in(author)
    expected = I18n.t("shared.run_switcher.run_label",
                      :ordinal => 1,
                      :date => I18n.l(game.current_run.starts_at.to_date, :format => :long))

    [ show_full_log_path(:game_id => game.id),
      show_live_channel_path(:game_id => game.id),
      show_game_log_path(:game_id => game.id, :team_id => team.id),
      show_level_log_path(:game_id => game.id, :team_id => team.id) ].each do |path|
      get path
      expect(response.body).to include(expected), "expected #{path} to name run 1"
    end
  end

  # ?run=1 must label itself run 1, not the run that happens to be current.
  it "names the run being viewed, not the current one" do
    open_second_run
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include("Забег №1")
  end

  # A draft game's run has no start date. Rendering "—" rather than raising is
  # the same rule the switcher already followed.
  it "renders a dash for a run with no start date" do
    game.current_run.update_column(:starts_at, nil)
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Забег №1")
  end

  # The counts describe the RUN, not the game -- the same distinction that
  # produced the @teams scoping bug in the run-scoped-logs work, where a
  # game-scoped query returned plausible but wrong rows.
  it "counts the teams of the run being viewed, not of the game" do
    open_second_run
    other = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => other, :game_run => game.current_run)
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(
      I18n.t("shared.run_context.counts", :teams => 1, :levels => 1))
  end

  it "offers the other run as a link on all four screens" do
    open_second_run
    sign_in(author)

    [ show_full_log_path(:game_id => game.id),
      show_live_channel_path(:game_id => game.id),
      show_game_log_path(:game_id => game.id, :team_id => team.id),
      show_level_log_path(:game_id => game.id, :team_id => team.id) ].each do |path|
      get path
      expect(Capybara.string(response.body))
        .to have_link(:href => %r{run=1}), "expected #{path} to link run 1"
    end
  end

  # ?run= and ?page= must survive each other: the href is built from
  # request.path plus the EXISTING query parameters, so switching run from
  # page 2 stays on page 2 rather than silently returning to the first.
  it "keeps the page when switching run, and the run when paging" do
    25.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    open_second_run
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :page => 2)

    page = Capybara.string(response.body)
    expect(page).to have_link(:href => %r{page=2})
    expect(page).to have_link(:href => %r{run=1})
    expect(page.find_link(:href => %r{run=1})[:href]).to include("page=2")
  end

  # THE frozen-scenario guard: features/logs/log.feature renders these pages
  # for single-run games, and a switcher where there was none would change
  # what they read.
  it "renders no switcher at all for a game with one run" do
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).not_to include(I18n.t("shared.run_switcher.heading"))
  end

  # Derived from the RUN on screen. Game#starts_at delegates to current_run,
  # so a game with a second run would otherwise report run 2's offset while
  # displaying run 1 -- wrong across a DST boundary.
  it "states the offset of the run being viewed" do
    author.update!(:timezone => "Berlin")
    game.current_run.update_column(:starts_at, Time.utc(2024, 8, 6, 9, 0, 0))
    open_second_run
    game.current_run.update_column(:starts_at, Time.utc(2024, 12, 15, 9, 0, 0))
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :run => 1)

    expect(response.body).to include(I18n.t("shared.times_in_zone", :zone => "+02:00"))
    expect(response.body).not_to include(I18n.t("shared.times_in_zone", :zone => "+01:00"))
  end
end
