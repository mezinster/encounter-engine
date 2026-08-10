# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for the 7 games/* templates, exercising real
# path helpers and every locale key each template reads.
#
# game_stats_path used to be a landmine here: the route carried a dynamic
# :action segment, so the helper demanded an explicit one, unlike Merb's
# url(:game_stats, ...) which silently defaulted it to "index". The route is
# now two static ones (see config/routes.rb) and the helper takes just the
# game, so the landmine is gone.
RSpec.describe "games/_list", type: :view do
  it "shows a plain view link to a non-author viewer" do
    game = create_game
    view.define_singleton_method(:logged_in?) { false }

    render partial: "games/list", locals: { games: [game] }

    expect(rendered).to include(game.name)
    expect(rendered).to include(I18n.t("games.list.view"))
    expect(rendered).not_to include(I18n.t("shared.edit_short"))
  end

  it "shows author-only controls for a started game, including the game_stats landmine fix" do
    author = create_user
    # Game validates starts_at can't be in the past at save time, so build it
    # with a near-future start and advance Time.now past it -- same
    # technique spec/models/game/started_spec.rb uses to get a "started"
    # game without fighting that validation.
    game = create_game(author: author, starts_at: 1.minute.from_now)
    allow(Time).to receive(:now).and_return(1.hour.from_now)

    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { author }

    render partial: "games/list", locals: { games: [game] }

    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.edit_short")))
    expect(rendered).to include(edit_game_path(game))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.list.stats")))
    # The landmine: Merb's url(:game_stats, game_id: game.id) relied on the
    # request's own :action falling back into the route; Rails has no such
    # fallback, so the view must supply action: "index" explicitly to keep
    # generating /stats/index/<id> instead of raising
    # ActionController::UrlGenerationError.
    expect(rendered).to include(game_stats_path(game))
    expect(rendered).to include("/stats/index/#{game.id}")
    expect(rendered).to include(show_live_channel_path(game.id))
    expect(rendered).to include(show_full_log_path(game.id))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.list.end_game")))
    expect(rendered).to include("/games/end_game/#{game.id}")
  end

  it "shows the author-finished message instead of the end-game link once the author has finished it" do
    author = create_user
    game = create_game(author: author, starts_at: 1.minute.from_now)
    game.finish_game!
    allow(Time).to receive(:now).and_return(1.hour.from_now)

    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { author }

    render partial: "games/list", locals: { games: [game] }

    expect(rendered).to include(I18n.t("games.list.author_finished"))
    expect(rendered).not_to include("/games/end_game/#{game.id}")
  end

  it "does not offer the end-game link while the game is in test mode" do
    author = create_user
    game = create_game(author: author, starts_at: 1.minute.from_now,
                       is_testing: true, test_date: 1.day.from_now)
    allow(Time).to receive(:now).and_return(1.hour.from_now)

    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { author }

    render partial: "games/list", locals: { games: [game] }

    expect(rendered).not_to include("/games/end_game/#{game.id}")
  end

  # Whole-branch review, mutant M7: `game.paused_at || Time.now` mutated to
  # plain `Time.now`. Nothing noticed, because no example paused a game and
  # then let more real time pass before rendering. The freeze-at-pause
  # behaviour is deliberate (games_helper.rb mirrors GamePassing#effective_now)
  # -- a running game's duration must stop growing the moment it is paused.
  it "freezes a running game's duration at pause time, not the current clock" do
    author = create_user
    # A literal, whole-second starts_at rather than N.from_now -- hours_and_minutes
    # truncates its float diff with #to_i, and a Time.now-derived starts_at
    # carries sub-microsecond noise that survives a datetime column round-trip
    # unevenly, landing the diff a hair under a whole second and flaking this
    # example between "1 ч 0 мин" and "0 ч 59 мин" for reasons with nothing to
    # do with what it is meant to test.
    started_at = Time.utc(2026, 3, 10, 9, 0, 0)
    allow(Time).to receive(:now).and_return(started_at - 1.day) # so creation's "must start in the future" validation passes
    game = create_game(author: author, starts_at: started_at)

    allow(Time).to receive(:now).and_return(started_at + 1.hour)
    game.pause! # paused_at = started_at + 1h

    allow(Time).to receive(:now).and_return(started_at + 3.hours) # clock keeps moving

    view.define_singleton_method(:logged_in?) { false }

    render partial: "games/list", locals: { games: [game] }

    expect(rendered).to include(I18n.t("games.list.duration", :hours => 1, :minutes => 0))
    expect(rendered).not_to include(I18n.t("games.list.duration", :hours => 3, :minutes => 0))
  end

  # Whole-branch review, mutant M12: dropping `game.status == :finished &&`
  # from the end-time condition (games/_list.html.erb). Nothing noticed
  # because no example covers a game that is BOTH finished and withdrawn --
  # :withdrawn wins Game#status's precedence, so the shipped condition
  # correctly hides the end time (arguably a defect worth revisiting on its
  # own, per the review, but not in this wave's scope). Withdrawn games are
  # excluded from /games but not from the dashboard, so this state does
  # render somewhere in production.
  it "shows no end time for a game that was finished and later withdrawn" do
    game = create_game
    set_game_schedule!(game, :starts_at => 2.hours.ago, :author_finished_at => 1.hour.ago)
    game.withdraw!

    view.define_singleton_method(:logged_in?) { false }

    render partial: "games/list", locals: { games: [game] }

    expect(rendered).to include(I18n.t("games.list.status_withdrawn"))
    expect(rendered).not_to include(I18n.l(game.author_finished_at, :format => :long))
  end
end

RSpec.describe "games/_game_entries", type: :view do
  it "lists an application with accept/reject links" do
    game = create_game
    team = create_team
    entry = GameEntry.create!(game: game, team: team, status: "new")

    render partial: "games/game_entries", locals: { game_entries: [entry] }

    expect(rendered).to include(I18n.t("games.game_entries.legend"))
    expect(rendered).to include(team.name)
    expect(rendered).to include(game.name)
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.game_entries.accept")))
    expect(rendered).to include("/game_entries/accept/#{entry.id}")
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.game_entries.reject")))
    expect(rendered).to include("/game_entries/reject/#{entry.id}")
  end
end

RSpec.describe "games/_teams", type: :view do
  it "lists participating teams" do
    team = create_team

    render partial: "games/teams", locals: { teams: [team] }

    expect(rendered).to include(I18n.t("games.teams.legend"))
    expect(rendered).to include(team.name)
  end
end

RSpec.describe "games/index", type: :view do
  it "renders the games list partial" do
    game = create_game

    assign(:games, [game])
    view.define_singleton_method(:logged_in?) { false }

    render

    expect(rendered).to include(game.name)
  end
end

RSpec.describe "games/new", type: :view do
  it "renders the new-game form" do
    assign(:game, Game.new)

    render

    expect(rendered).to include(I18n.t("games.form.name"))
    expect(rendered).to include(I18n.t("games.form.description"))
    expect(rendered).to include(I18n.t("games.form.starts_at"))
    expect(rendered).to include(I18n.t("games.form.registration_deadline"))
    expect(rendered).to include(I18n.t("games.form.max_team_number"))
    expect(rendered).to include(I18n.t("games.form.is_draft"))
    expect(rendered).to include(I18n.t("games.new.submit"))
    expect(rendered).to include(games_path)
  end

  it "renders validation errors with the shared error header" do
    game = Game.new
    game.valid?
    assign(:game, game)

    render

    expect(rendered).to include(I18n.t("shared.error_header"))
  end
end

RSpec.describe "games/edit", type: :view do
  it "renders the edit-game form with a cancel link" do
    game = create_game

    assign(:game, game)

    render

    expect(rendered).to include(I18n.t("games.edit.submit"))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
    expect(rendered).to include(game_path(game))
  end
end

RSpec.describe "games/show", type: :view do
  it "renders game details for a guest, using the short numeric date format" do
    game = create_game(
      starts_at: Time.utc(2050, 3, 21, 18, 1),
      registration_deadline: Time.utc(2050, 3, 19, 18, 1)
    )

    assign(:game, game)
    assign(:game_entries, [])
    assign(:teams, [])
    view.define_singleton_method(:logged_in?) { false }
    # content_locale_for is a helper_method on ApplicationController (Task 5);
    # isolated view specs don't run through the real controller stack, so it
    # has to be stubbed the same way it is in spec/views/game_passings_spec.rb.
    # A single-locale game's content locale is always its primary_locale.
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).to include(game.name)
    expect(rendered).to include(game.author.nickname)
    # features/games/create-game.feature and
    # features/games/registration-deadline.feature assert this exact literal
    # "%Y-%m-%d %H:%M" numeric string -- NOT a long/spelled-out format.
    expect(rendered).to include("2050-03-21 18:01")
    expect(rendered).to include("2050-03-19 18:01")
    expect(rendered).to include(game.description)
  end

  it "shows the author-only controls (levels, entries, teams, edit/delete) for the author" do
    author = create_user
    game = create_game(author: author)
    level = create_level(game: game)

    assign(:game, game)
    assign(:game_entries, [])
    assign(:teams, [])
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { author }
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }
    assign(:current_user, author)

    render

    expect(rendered).to include(I18n.t("games.show.levels_legend"))
    expect(rendered).to include(level.name)
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.show.add_level")))
    expect(rendered).to include(new_game_level_path(game))
    expect(rendered).to include(I18n.t("games.game_entries.legend"))
    expect(rendered).to include(I18n.t("games.teams.legend"))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.show.edit_link")))
    expect(rendered).to include(edit_game_path(game))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.show.delete_link")))
    expect(rendered).to include(delete_game_path(game))
  end

  it "shows the start-test link for a draft game with levels, not yet started" do
    author = create_user
    game = create_game(author: author, starts_at: nil, is_draft: true)
    create_level(game: game)

    assign(:game, game)
    assign(:game_entries, [])
    assign(:teams, [])
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).to include(ERB::Util.html_escape(I18n.t("games.show.start_test")))
    expect(rendered).to include("/games/start_test/#{game.id}")
  end
end
