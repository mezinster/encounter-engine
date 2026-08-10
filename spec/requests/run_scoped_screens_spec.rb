# -*- encoding : utf-8 -*-
require "rails_helper"

# Every screen that shows results or logs must show ONE run's. All of these
# build a second run: with a single run each of these queries returns what the
# game-scoped version returned, so an example without one proves nothing.
describe "screens scoped to a run", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 1.hour.ago)
    g
  end
  let(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A team whose passing and log live in a run that is NOT the current one.
  # Captures the run BEFORE the second one is opened -- create_next_run raises
  # the ordinal, so current_run answers with the new run afterwards.
  #
  # Teams are asserted on by their generated name, not a literal: create_team
  # ignores a :name option and always generates one, so an assertion on a
  # literal would never match and the example would fail whatever the code did.
  def team_in_old_run
    old_run = game.current_run
    team = create_team(:captain => create_user)
    passing = create_game_passing(:level => level, :team => team, :game_run => old_run)
    passing.update_column(:finished_at, 2.days.ago)
    create_log(:game => game, :level => level, :team => team,
               :game_run => old_run, :answer => "старыйкод")
    team
  end

  def open_second_run
    create_next_run(game)
    game.reload
  end

  it "shows only the current run's teams in the results table" do
    old = team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user)
    p = create_game_passing(:level => level, :team => current_team, :game_run => game.current_run)
    p.update_column(:finished_at, 1.hour.ago)

    get game_passings_show_results_path(:game_id => game.id)

    expect(response.body).to include(current_team.name)
    expect(response.body).not_to include(old.name)
  end

  it "shows only the current run's answers in the live channel" do
    team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user)
    create_log(:game => game, :level => level, :team => current_team,
               :game_run => game.current_run, :answer => "новыйкод")
    sign_in(author)

    get show_live_channel_path(:game_id => game.id)

    expect(response.body).to include("новыйкод")
    expect(response.body).not_to include("старыйкод")
  end

  # The full log builds its team columns from the game_passings, not from the
  # log rows, so this team needs a passing as well as a log -- with only a log
  # it has no column and the answer is never rendered.
  it "shows only the current run's answers in the full log" do
    team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => current_team, :game_run => game.current_run)
    create_log(:game => game, :level => level, :team => current_team,
               :game_run => game.current_run, :answer => "новыйкод")
    sign_in(author)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include("новыйкод")
    expect(response.body).not_to include("старыйкод")
  end

  it "lists only the current run's passings for the author" do
    old = team_in_old_run
    open_second_run
    current_team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => current_team, :game_run => game.current_run)
    sign_in(author)

    get game_stats_path(:game_id => game.id)

    expect(response.body).to include(current_team.name)
    expect(response.body).not_to include(old.name)
  end

  # finish_test DELETES player history, which is why it is scoped rather than
  # left game-wide: in phase 3 a test run must not erase a real run's results.
  #
  # Its own game, deliberately not the started `game` above: finish_test calls
  # @game.save, and game_starts_in_the_future refuses any game whose starts_at
  # is past while author_finished_at is nil -- so on a started game the save
  # fails, the action redirects with an alert, and nothing is deleted. The
  # example would then pass without ever exercising the deletion.
  it "deletes only the current run's passings and logs when a test is finished" do
    tested = create_game(:author => author, :is_draft => true)
    tested_level = create_level(:game => tested)
    old_run = tested.current_run
    old_team = create_team(:captain => create_user)
    create_game_passing(:level => tested_level, :team => old_team, :game_run => old_run)
    create_log(:game => tested, :level => tested_level, :team => old_team,
               :game_run => old_run, :answer => "старыйкод")

    create_next_run(tested)
    tested.reload
    new_team = create_team(:captain => create_user)
    create_game_passing(:level => tested_level, :team => new_team, :game_run => tested.current_run)
    create_log(:game => tested, :level => tested_level, :team => new_team,
               :game_run => tested.current_run, :answer => "новыйкод")

    sign_in(author)
    post finish_test_game_path(tested)

    expect(GamePassing.where(:game_run_id => old_run.id).count).to eq(1)
    expect(Log.where(:game_run_id => old_run.id).count).to eq(1)

    # Counted over the whole GAME, not by game_run_id. A run-scoped count
    # cannot tell deletion from nullification, and delete_all on a has_many
    # proxy with no dependent: option nullifies -- which is exactly the bug
    # this example failed to catch until GamesController#finish_test was
    # changed to delete through a relation instead.
    expect(GamePassing.where(:game_id => tested.id).count).to eq(1)
    expect(Log.where(:game_id => tested.id).count).to eq(1)
  end
end
