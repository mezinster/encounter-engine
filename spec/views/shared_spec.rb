# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "shared/_game_entry_controls", type: :view do
  it "renders the open-registration state when no entry exists yet" do
    game = create_game(max_team_number: 5)
    team = create_team

    render partial: "shared/game_entry_controls",
           locals: { game_entry: nil, game: game, team: team }

    expect(rendered).to include(I18n.t("shared.game_entry_controls.apply"))
    expect(rendered).to include(new_game_entry_path(game_id: game.id, team_id: team.id))
  end

  it "renders the exceeded-capacity state" do
    game = create_game(max_team_number: 1, requested_teams_number: 1)
    team = create_team

    render partial: "shared/game_entry_controls",
           locals: { game_entry: nil, game: game, team: team }

    expect(rendered).to include(I18n.t("shared.game_entry_controls.entries_exceeded"))
  end
end

RSpec.describe "shared/_current_games_status", type: :view do
  it "renders the play link for an accepted entry" do
    game = create_game
    game_entry = double("GameEntry", status: "accepted")

    render partial: "shared/current_games_status",
           locals: { game_entry: game_entry, game: game }

    expect(rendered).to include(I18n.t("shared.current_games_status.play"))
    expect(rendered).to include(show_current_level_path(game_id: game.id))
  end

  it "renders the not-registered message for an entry in a non-accepted status" do
    game = create_game
    game_entry = double("GameEntry", status: "recalled")

    render partial: "shared/current_games_status",
           locals: { game_entry: game_entry, game: game }

    expect(rendered).to include(I18n.t("shared.current_games_status.not_registered"))
  end

  # A gated game never creates a GameEntry -- game_entry is nil for it -- so
  # this is a second branch entirely, not a third game_entry.status value.
  it "renders the play link for a gated game the team may currently play" do
    game = create_game(:access_mode => "pass_required")

    render partial: "shared/current_games_status",
           locals: { game_entry: nil, game: game, gated_live: true }

    expect(rendered).to include(I18n.t("shared.current_games_status.play"))
    expect(rendered).to include(show_current_level_path(game_id: game.id))
  end

  it "renders the access-required message for a gated game the team has no live pass or attempt for" do
    game = create_game(:access_mode => "pass_required")

    render partial: "shared/current_games_status",
           locals: { game_entry: nil, game: game, gated_live: false }

    expect(rendered).to include(I18n.t("errors.no_access_pass"))
  end

  it "renders the access-required message for a gated game when gated_live is not passed at all" do
    game = create_game(:access_mode => "pass_required")

    render partial: "shared/current_games_status",
           locals: { game_entry: nil, game: game }

    expect(rendered).to include(I18n.t("errors.no_access_pass"))
  end
end

RSpec.describe "shared/_current_games", type: :view do
  it "renders nothing for a user without a team" do
    user = create_user
    view.define_singleton_method(:current_user) { user }

    render partial: "shared/current_games"

    expect(rendered.strip).to eq("")
  end
end

RSpec.describe "shared/_countdown", type: :view do
  it "compiles the countdown script with translated plural word lists" do
    game = create_game
    assign(:game, game)
    assign(:team, nil)
    view.define_singleton_method(:logged_in?) { false }

    render partial: "shared/countdown"

    expect(rendered).to include(I18n.t("shared.countdown.prefix"))
    expect(rendered).to include(I18n.t("shared.countdown.years").to_json)
  end
end
