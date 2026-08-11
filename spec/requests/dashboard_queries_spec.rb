# -*- encoding : utf-8 -*-
require "rails_helper"

# The dashboard renders every game an author owns, and asked the database
# about each one separately -- twice. DashboardController#index loaded
# @games with no preload, so `game.current_run` (Game#current_run is
# `runs.to_a.last`) fetched that game's runs on its own, and the loop beside
# it ran one GameEntry query per game on top.
#
# Measured before the fix: 17 queries for one game, 44 for ten. Three per
# game, on the page an author opens most often, growing with the thing an
# active author accumulates.
#
# Asserted as a SLOPE rather than an exact number, the shape
# spec/requests/games_listing_spec.rb and admin_console_spec.rb both use: a
# count pinned to a magic value breaks on any unrelated query added elsewhere
# and still says nothing about whether it grows with the collection.
describe "the dashboard's query count", type: :request do
  let(:author) { create_user }

  before { put login_path, :params => { :email => author.email, :password => "1234" } }

  def author_game
    game = create_game(:author => author, :is_draft => false)
    # A team registered on the run, so both per-game queries have something to
    # find. An empty association can hide an N+1: one query per game returning
    # nothing still counts, but a fix that batches only the non-empty case
    # would pass anyway.
    create_game_entry(:game => game, :team => create_team(:captain => create_user),
                      :status => "new")
    create_game_entry(:game => game, :team => create_team(:captain => create_user),
                      :status => "accepted")
    game
  end

  it "does not grow with the number of games the author owns" do
    author_game
    one = count_queries { get dashboard_path }

    9.times { author_game }
    ten = count_queries { get dashboard_path }

    expect(ten).to eq(one),
      "the dashboard issued #{one} queries for one game and #{ten} for ten -- " \
      "something in DashboardController#index or its partials is per-game"
  end

  # The counts above are only meaningful if the page still says the same
  # things, so pin the two collections the per-game queries fed.
  it "still lists the games, their pending entries and their accepted teams" do
    game = create_game(:author => author, :is_draft => false, :name => "Проверка")
    pending  = create_game_entry(:game => game, :team => create_team(:captain => create_user),
                                 :status => "new")
    accepted = create_game_entry(:game => game, :team => create_team(:captain => create_user),
                                 :status => "accepted")

    get dashboard_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Проверка")
    expect(response.body).to include(pending.team.name)
    expect(response.body).to include(accepted.team.name)
  end

  # An author on their game's SECOND run must see that run's registrations,
  # not every cohort that ever played -- the property #accepted_teams_by_game
  # documents and the batched pending-entry query has to preserve too.
  it "shows only the current run's entries when a game has been run twice" do
    game = create_game(:author => author, :is_draft => false)
    old_team = create_team(:captain => create_user)
    create_game_entry(:game => game, :team => old_team, :status => "accepted")

    create_next_run(game)
    new_team = create_team(:captain => create_user)
    create_game_entry(:game => game, :team => new_team, :status => "accepted",
                      :game_run => game.reload.current_run)

    get dashboard_path

    expect(response.body).to include(new_team.name)
    expect(response.body).not_to include(old_team.name)
  end
end
