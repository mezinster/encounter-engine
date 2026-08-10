# -*- encoding : utf-8 -*-
require "rails_helper"

# Results belong to a RUN, not to a game. Every example here builds a second
# run, because with one run a run-scoped query returns exactly what the
# game-scoped one returned and would pass either way.
RSpec.describe GameRun, "results" do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }

  def finished_passing(run, team, finished_at, penalty = 0)
    passing = create_game_passing(:level => level, :team => team, :game_run => run)
    passing.update_column(:finished_at, finished_at)
    passing.update_column(:penalty_seconds, penalty)
    passing
  end

  it "lists only its own passings" do
    run_one = game.current_run
    run_two = create_next_run(game)
    mine = create_game_passing(:level => level, :game_run => run_one)
    create_game_passing(:level => level, :game_run => run_two)

    expect(run_one.passings.map(&:id)).to eq([ mine.id ])
  end

  it "finds a team's passing within itself only" do
    run_one = game.current_run
    run_two = create_next_run(game)
    team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => team, :game_run => run_two)

    expect(run_one.passing_for(team)).to be_nil
    expect(run_two.passing_for(team)).to be_present
  end

  it "counts only its own finished teams" do
    run_one = game.current_run
    run_two = create_next_run(game)
    mine = create_team(:captain => create_user)
    theirs = create_team(:captain => create_user)
    finished_passing(run_one, mine, 1.hour.ago)
    finished_passing(run_two, theirs, 1.hour.ago)

    expect(run_one.finished_teams).to eq([ mine ])
  end

  it "ranks within its own run" do
    run = game.current_run
    first = create_team(:captain => create_user)
    second = create_team(:captain => create_user)
    finished_passing(run, first, 3.hours.ago)
    finished_passing(run, second, 1.hour.ago)

    expect(run.place_of(first)).to eq(1)
    expect(run.place_of(second)).to eq(2)
  end

  # THE example this whole programme exists for. A team that finished earlier
  # in absolute wall-clock time in an EARLIER run must not take a place from a
  # later run's ranking -- which is precisely what game-scoped, absolute-time
  # ranking did.
  it "is not affected by a team that finished earlier in another run" do
    run_one = game.current_run
    run_two = create_next_run(game)
    old_timer = create_team(:captain => create_user)
    newcomer  = create_team(:captain => create_user)
    finished_passing(run_one, old_timer, 30.days.ago)
    finished_passing(run_two, newcomer, 1.hour.ago)

    expect(run_two.place_of(newcomer)).to eq(1)
  end

  it "returns nil for a team that has not finished" do
    run = game.current_run
    team = create_team(:captain => create_user)
    create_game_passing(:level => level, :team => team, :game_run => run)

    expect(run.place_of(team)).to be_nil
  end

  # Penalties still count, and still within the run.
  it "ranks a penalised early finisher behind a clean later one" do
    run = game.current_run
    guesser = create_team(:captain => create_user)
    steady  = create_team(:captain => create_user)
    finished_passing(run, guesser, 2.hours.ago, 7200)
    finished_passing(run, steady, 90.minutes.ago, 0)

    expect(run.place_of(steady)).to eq(1)
  end

  describe "Game's delegations" do
    it "answers place_of from the current run" do
      run = game.current_run
      team = create_team(:captain => create_user)
      finished_passing(run, team, 1.hour.ago)

      expect(game.place_of(team)).to eq(run.place_of(team))
    end

    it "answers finished_teams from the current run" do
      run = game.current_run
      team = create_team(:captain => create_user)
      finished_passing(run, team, 1.hour.ago)

      expect(game.finished_teams).to eq(run.finished_teams)
    end
  end
end
