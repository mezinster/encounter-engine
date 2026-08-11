# -*- encoding : utf-8 -*-
require "rails_helper"

# The "Команды" column of games/_list, which is rendered from games/index and
# from the dashboard.
#
# Every other counting site in this application is scoped to the current run --
# GamesController#show (GameEntry.of_run), GamePassingsController#index
# (current_run.passings), the dashboard, the admin entries console. This
# helper was the one that was not: it grouped by game_id alone, so on a game
# that has been run more than once it summed registrations and passings across
# EVERY run and divided them by a max_team_number that Game delegates to the
# current run only (app/models/game.rb). A second run therefore made the
# numerator and the denominator answer different questions.
#
# Two runs in the examples below is not thoroughness for its own sake: with a
# single run every run-scoped query returns exactly what the game-scoped one
# returned, and an example without a second run passes whether the scoping
# works or not.
describe GamesHelper, :type => :helper do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :max_team_number => 10) }

  describe "#game_team_counts" do
    it "counts the accepted registrations of the current run only" do
      create_game_entry(:game => game, :team => create_team, :status => "accepted")
      old_run = game.current_run
      create_next_run(game)
      create_game_entry(:game => game, :team => create_team, :status => "accepted",
                        :game_run => game.reload.current_run)

      counts = helper.game_team_counts([game])

      expect(old_run.id).not_to eq(game.current_run.id)
      expect(counts[:registered].fetch(game.id, 0)).to eq(1)
    end

    it "counts the teams that took part in the current run only" do
      level = create_level(:game => game)
      create_game_passing(:level => level, :game_run => game.current_run)
      create_next_run(game)
      create_game_passing(:level => level, :game_run => game.reload.current_run)

      counts = helper.game_team_counts([game])

      expect(counts[:played].fetch(game.id, 0)).to eq(1)
    end

    it "counts the teams still playing the current run only" do
      level = create_level(:game => game)
      create_game_passing(:level => level, :game_run => game.current_run)
      create_next_run(game)
      create_game_passing(:level => level, :game_run => game.reload.current_run)

      counts = helper.game_team_counts([game])

      expect(counts[:playing].fetch(game.id, 0)).to eq(1)
    end

    # The reason the exclusion is written as
    # `where(status: nil).or(where.not(status: %w[exited ended]))` rather than
    # the obvious NOT IN: status is nullable and nil is the ordinary
    # in-progress value, and `status NOT IN (...)` is NULL -- and therefore
    # false -- for every nil-status row, which would zero out the common case.
    it "keeps a nil-status passing in the playing count" do
      level = create_level(:game => game)
      create_game_passing(:level => level, :game_run => game.current_run)

      counts = helper.game_team_counts([game])

      expect(counts[:playing].fetch(game.id, 0)).to eq(1)
    end

    it "leaves out a team that exited and one an operator ended" do
      level = create_level(:game => game)
      create_game_passing(:level => level, :game_run => game.current_run).exit!
      create_game_passing(:level => level, :game_run => game.current_run).end!

      counts = helper.game_team_counts([game])

      expect(counts[:playing].fetch(game.id, 0)).to eq(0)
      expect(counts[:played].fetch(game.id, 0)).to eq(2)
    end

    # The memoisation is keyed on the exact set of ids, so a page rendering the
    # partial twice with different collections must not reuse the wrong entry.
    it "does not reuse one collection's counts for another" do
      other = create_game(:author => author)
      create_game_entry(:game => game, :team => create_team, :status => "accepted")

      first  = helper.game_team_counts([game])
      second = helper.game_team_counts([other])

      expect(first[:registered].fetch(game.id, 0)).to eq(1)
      expect(second[:registered].fetch(other.id, 0)).to eq(0)
    end
  end

  describe "#game_participation_text" do
    it "reports who is currently playing a running game" do
      level = create_level(:game => game)
      create_game_passing(:level => level, :game_run => game.current_run)
      set_game_schedule!(game, :starts_at => 1.hour.ago)

      text = helper.game_participation_text(game.reload, helper.game_team_counts([game]))

      expect(text).to eq(I18n.t("games.list.playing", :count => 1))
    end

    # A running game whose teams have all finished would otherwise render
    # byte-identical to a scheduled game nobody joined, for as long as the
    # author takes to press "end game".
    it "falls back to who took part once nobody is still playing" do
      level = create_level(:game => game)
      create_game_passing(:level => level, :game_run => game.current_run).exit!
      set_game_schedule!(game, :starts_at => 1.hour.ago)

      text = helper.game_participation_text(game.reload, helper.game_team_counts([game]))

      expect(text).to eq(I18n.t("games.list.played", :count => 1))
    end

    it "says nothing about a scheduled game nobody has joined" do
      set_game_schedule!(game, :starts_at => 1.hour.from_now)

      text = helper.game_participation_text(game.reload, helper.game_team_counts([game]))

      expect(text).to be_nil
    end
  end
end
