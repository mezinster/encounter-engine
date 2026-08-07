# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "logs/index", type: :view do
  it "renders its ported (unreachable, no route) placeholder title" do
    render

    expect(rendered).to include(I18n.t("logs.index.title"))
  end
end

RSpec.describe "logs/show_full_log", type: :view do
  it "renders each level's correct answer(s) and every team's submission log" do
    # create_level's own fixture default builds one question via
    # Level#correct_answer=; override it directly so the level has exactly
    # the single question this test asserts on (a second create_question
    # call would push it into the plural "correct_answer_many" branch).
    level = create_level(correct_answer: "enone")
    team = create_team

    Log.create!(game_id: level.game_id, team: team.name, level: level.name, answer: "wrong", time: Time.current)

    assign(:levels, [level])
    assign(:teams, [team])

    render

    expect(rendered).to include(I18n.t("logs.show_full_log.title"))
    expect(rendered).to include(I18n.t("logs.show_full_log.correct_answer_one"))
    expect(rendered).to include("enone")
    expect(rendered).to include(team.name)
    expect(rendered).to include("wrong")
  end

  it "uses the plural correct-answer label for a multi-question level" do
    level = create_level
    create_question(level: level, correct_answer: "enone")
    create_question(level: level, correct_answer: "en1")

    assign(:levels, [level])
    assign(:teams, [])

    render

    expect(rendered).to include(I18n.t("logs.show_full_log.correct_answer_many"))
  end
end

RSpec.describe "logs/show_game_log", type: :view do
  it "renders every level of the game with its correct answer and log entries" do
    team = create_team
    level = create_level
    game = level.game
    create_question(level: level, correct_answer: "enone")
    # The view no longer re-queries Log.of_game(level) itself (see the
    # security fix under .superpowers/sdd/2026-08-07-security-data-exposure) --
    # it now scopes the controller-supplied @logs down to the current level
    # via Log.of_level, so the view local test must assign :logs the same way
    # LogsController#show_game_log does: Log.of_game(@game).of_team(@team).
    Log.create!(game_id: game.id, team: team.name, level: level.name, answer: "enone", time: Time.current)

    assign(:game, game)
    assign(:team, team)
    assign(:logs, Log.of_game(game).of_team(team))

    render

    expect(rendered).to include(ERB::Util.html_escape(I18n.t("logs.show_game_log.title", team: team.name, game: game.name)))
    expect(rendered).to include(I18n.t("logs.show_game_log.correct_answer"))
    expect(rendered).to include("enone")
  end
end

RSpec.describe "logs/show_level_log", type: :view do
  it "renders the level's correct answer and the team's submission log" do
    level = create_level
    game = level.game
    team = create_team
    create_question(level: level, correct_answer: "enone")
    log = Log.create!(game_id: game.id, team: team.name, level: level.name, answer: "enone", time: Time.current)

    assign(:team, team)
    assign(:level, level)
    assign(:game, game)
    assign(:logs, [log])

    render

    expect(rendered).to include(ERB::Util.html_escape(I18n.t("logs.show_level_log.title", team: team.name, level: level.name, game: game.name)))
    expect(rendered).to include(I18n.t("logs.show_level_log.correct_answer"))
    expect(rendered).to include("enone")
  end
end

RSpec.describe "logs/show_live_channel", type: :view do
  it "renders a table of every submission across the game" do
    game = create_game
    log1 = Log.create!(game_id: game.id, team: "A", level: "L1", answer: "x", time: 1.minute.ago)
    log2 = Log.create!(game_id: game.id, team: "B", level: "L1", answer: "y", time: Time.current)

    assign(:game, game)
    assign(:logs, [log1, log2])

    render

    expect(rendered).to include(ERB::Util.html_escape(I18n.t("logs.show_live_channel.title", name: game.name)))
    expect(rendered).to include(I18n.t("logs.show_live_channel.time"))
    expect(rendered).to include(I18n.t("logs.show_live_channel.team"))
    expect(rendered).to include(I18n.t("logs.show_live_channel.level"))
    expect(rendered).to include(I18n.t("logs.show_live_channel.code"))
    expect(rendered).to include("x")
    expect(rendered).to include("y")
  end
end
