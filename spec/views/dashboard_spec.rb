# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "dashboard/_my_team", type: :view do
  it "shows the create-team prompt and pending invitations for a teamless user" do
    user = create_user
    invitation = create_invitation(for: user)
    assign(:current_user, user)
    assign(:invitations, [invitation])

    render partial: "dashboard/my_team"

    expect(rendered).to include(I18n.t("dashboard.my_team.no_team"))
    expect(rendered).to include(new_team_path)
    expect(rendered).to include(I18n.t("dashboard.my_team.invited", team: invitation.to_team.name))
    expect(rendered).to include(I18n.t("dashboard.my_team.accept"))
    expect(rendered).to include("/invitations/accept/#{invitation.id}")
    expect(rendered).to include(I18n.t("dashboard.my_team.decline"))
    expect(rendered).to include("/invitations/reject/#{invitation.id}")
  end

  it "shows the team name and room link for a team member" do
    captain = create_user
    team = create_team(captain: captain)
    captain.reload
    assign(:current_user, captain)
    assign(:invitations, [])

    render partial: "dashboard/my_team"

    expect(rendered).to include(I18n.t("dashboard.my_team.captain_of"))
    expect(rendered).to include(team.name)
    expect(rendered).to include(I18n.t("dashboard.my_team.go_to_team_room"))
    expect(rendered).to include(team_room_path)
  end
end

RSpec.describe "dashboard/_coming_games", type: :view do
  it "marks the author on their own upcoming game" do
    author = create_user
    game = create_game(author: author, starts_at: 1.day.from_now)
    assign(:current_user, author)
    view.define_singleton_method(:current_user) { author }

    render partial: "dashboard/coming_games"

    expect(rendered).to include(I18n.t("dashboard.coming_games.legend", count: Game.notstarted.count))
    expect(rendered).to include(I18n.t("dashboard.coming_games.upcoming"))
    expect(rendered).to include(game.name)
    expect(rendered).to include(I18n.t("dashboard.coming_games.you_are_author"))
  end

  it "shows entry controls and an enter link for a captain who isn't the author" do
    author = create_user
    create_game(author: author, starts_at: 1.day.from_now, max_team_number: 5)
    captain = create_user
    team = create_team(captain: captain)
    captain.reload

    assign(:current_user, captain)
    assign(:team, team)
    view.define_singleton_method(:current_user) { captain }

    render partial: "dashboard/coming_games"

    expect(rendered).to include(I18n.t("shared.game_entry_controls.apply"))
    expect(rendered).to include(I18n.t("dashboard.coming_games.enter"))
  end
end

RSpec.describe "dashboard/_finished_games", type: :view do
  it "lists a finished game with a link to its results" do
    game = create_game
    game.update!(author_finished_at: Time.current)

    render partial: "dashboard/finished_games"

    expect(rendered).to include(I18n.t("dashboard.finished_games.legend"))
    expect(rendered).to include(I18n.t("dashboard.finished_games.finished"))
    expect(rendered).to include(game.name)
    expect(rendered).to include(I18n.t("shared.current_games.view_results"))
    expect(rendered).to include(game_passings_show_results_path(game_id: game.id))
  end
end

RSpec.describe "dashboard/_my_games", type: :view do
  it "lists the current user's games and a create-game link" do
    author = create_user
    create_game(author: author)

    # games/_list.html.erb (rendered by dashboard/_my_games below) reads
    # both logged_in? and current_user -- Task 9c has ported it for real now,
    # so both need stubbing (the render stub that used to short-circuit
    # games/* partials is gone, per task-9c-report.md).
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { author }
    # The partial used to build this collection itself, with a second
    # Game.by(current_user) that discarded the controller's includes(:runs)
    # and made the games table fetch one game's runs at a time. It reads
    # @games now, so a view spec has to supply what
    # DashboardController#index does -- the same scope, preloaded.
    assign(:games, Game.by(author).includes(:runs))

    render partial: "dashboard/my_games"

    expect(rendered).to include(I18n.t("dashboard.my_games.legend", count: 1))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("dashboard.my_games.create")))
    expect(rendered).to include(new_game_path)
  end
end

RSpec.describe "dashboard/index", type: :view do
  it "renders the full dashboard shell for a user with a team" do
    captain = create_user
    team = create_team(captain: captain)
    captain.reload

    assign(:current_user, captain)
    assign(:team, team)
    assign(:invitations, [])
    assign(:games, [])
    assign(:game_entries, [])
    assign(:teams_by_game, {})

    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { captain }

    # Task 9c ported games/_game_entries.html.erb, games/_teams.html.erb,
    # and (via dashboard/_my_games) games/_list.html.erb -- the render stub
    # that used to short-circuit games/* partials (see task-9b-report.md) is
    # gone; every render call dashboard/index.html.erb makes now executes
    # for real.
    render

    expect(rendered).to include(I18n.t("dashboard.index.greeting"))
    expect(rendered).to include(captain.nickname)
    expect(rendered).to include(I18n.t("dashboard.my_team.legend"))
    expect(rendered).to include(I18n.t("dashboard.my_games.legend", count: 0))
    expect(rendered).to include(I18n.t("dashboard.coming_games.legend", count: Game.notstarted.count))
    expect(rendered).to include(I18n.t("dashboard.finished_games.legend"))
  end
end
