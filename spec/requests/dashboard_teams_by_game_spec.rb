# -*- encoding : utf-8 -*-
require "rails_helper"
require "capybara"

# DashboardController#index used to flatten every author's accepted teams
# into one @teams array with no dedup and no game attribution -- a team
# accepted into two of the author's games rendered twice under a single
# unlabeled list, with nothing saying which game either instance belonged
# to. This spec proves the dashboard instead groups accepted teams BY GAME
# (each game's name as its group heading), skips games with no accepted
# teams, and never leaks another author's teams into the wrong group.
describe "the dashboard's accepted-teams-by-game grouping", type: :request do
  def login(user)
    put login_path, params: { email: user.email, password: "1234" }
  end

  def accept(game, team)
    GameEntry.create!(:game => game, :team => team, :status => "accepted")
  end

  # Scopes to the single fieldset that legends "games.teams.legend" -- the
  # same shared legend games/show.html.erb uses, reused per the design --
  # so assertions below can't accidentally match an unrelated dashboard
  # section (e.g. "my games", which lists every game regardless of
  # accepted teams).
  def teams_fieldset(page)
    legend = I18n.t("games.teams.legend")
    page.find(:xpath, ".//fieldset[legend[normalize-space(text())=#{legend.inspect}]]")
  end

  # Finds the ancestor block that groups one game's heading with its team
  # list, so assertions can check "team X is under game Y's group" rather
  # than merely "team X appears somewhere on the page" -- which the old,
  # unlabeled, flat-concatenated list would also satisfy.
  def group_for(fieldset, game_name)
    heading = fieldset.find(:xpath, ".//*[normalize-space(text())=#{game_name.to_s.inspect}]")
    heading.find(:xpath, "./ancestor::*[self::li or self::div or self::section][1]")
  end

  it "shows a team's name under each game it is accepted into, and never under a game it isn't" do
    author = create_user
    game_one = create_game(:author => author, :name => "Игра Раз #{random_string}")
    game_two = create_game(:author => author, :name => "Игра Два #{random_string}")
    other_authors_game = create_game(:author => create_user, :name => "Чужая Игра #{random_string}")
    empty_game = create_game(:author => author, :name => "Пустая Игра #{random_string}")

    shared_team = create_team(:captain => create_user)
    accept(game_one, shared_team)
    accept(game_two, shared_team)

    other_authors_team = create_team(:captain => create_user)
    accept(other_authors_game, other_authors_team)

    login(author)
    get dashboard_path

    expect(response.body).to include(I18n.t("games.teams.legend"))

    page = Capybara.string(response.body)
    fieldset = teams_fieldset(page)

    game_one_group = group_for(fieldset, game_one.name)
    game_two_group = group_for(fieldset, game_two.name)

    # The shared team must appear under BOTH of the author's games -- not
    # once in a single unlabeled list, and not missing from either group.
    expect(game_one_group).to have_text(shared_team.name)
    expect(game_two_group).to have_text(shared_team.name)

    # A team accepted only into someone else's game must not appear under
    # this author's groups at all.
    expect(game_one_group).not_to have_text(other_authors_team.name)
    expect(game_two_group).not_to have_text(other_authors_team.name)

    # A game with zero accepted teams gets no group -- no wall of empty
    # headings for an author with several games. (Scoped to the teams
    # fieldset: empty_game legitimately still shows up under "my games".)
    expect(fieldset).not_to have_text(empty_game.name)
  end
end
