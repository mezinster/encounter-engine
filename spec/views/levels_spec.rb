# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for the 4 levels/* templates.
RSpec.describe "levels/_list", type: :view do
  it "shows a move-down link (not move-up) on the first of two levels, and vice versa" do
    game = create_game
    first_level = create_level(game: game, name: "First")
    second_level = create_level(game: game, name: "Second")

    render partial: "levels/list", locals: { levels: [first_level, second_level] }

    expect(rendered).to include(first_level.name)
    expect(rendered).to include(second_level.name)
    expect(rendered).to include(move_down_game_level_path(game, first_level))
    expect(rendered).not_to include(move_up_game_level_path(game, first_level))
    expect(rendered).to include(move_up_game_level_path(game, second_level))
    expect(rendered).not_to include(move_down_game_level_path(game, second_level))
  end

  it "shows both move-up and move-down links for a middle level" do
    game = create_game
    first_level = create_level(game: game, name: "First")
    middle_level = create_level(game: game, name: "Middle")
    last_level = create_level(game: game, name: "Last")

    render partial: "levels/list", locals: { levels: [first_level, middle_level, last_level] }

    expect(rendered).to include(move_up_game_level_path(game, middle_level))
    expect(rendered).to include(move_down_game_level_path(game, middle_level))
  end
end

RSpec.describe "levels/edit", type: :view do
  it "renders the edit-level form with a cancel link back to the level" do
    level = create_level

    assign(:level, level)

    render

    expect(rendered).to include(level.name)
    expect(rendered).to include(level.game.name)
    expect(rendered).to include(I18n.t("levels.form.name"))
    expect(rendered).to include(I18n.t("levels.form.text"))
    expect(rendered).to include(I18n.t("levels.edit.submit"))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
    expect(rendered).to include(game_level_path(level.game, level))
  end

  it "renders validation errors with the shared error header" do
    level = create_level
    level.name = ""
    level.valid?
    assign(:level, level)

    render

    expect(rendered).to include(I18n.t("shared.error_header"))
  end
end

RSpec.describe "levels/new", type: :view do
  it "renders the new-level form for the given game" do
    game = create_game
    level = game.levels.build

    assign(:game, game)
    assign(:level, level)

    render

    expect(rendered).to include(I18n.t("levels.new.heading", name: game.name))
    expect(rendered).to include(I18n.t("levels.form.name"))
    expect(rendered).to include(I18n.t("levels.form.text"))
    expect(rendered).to include(I18n.t("levels.form.correct_answer"))
    expect(rendered).to include(I18n.t("levels.new.hint_more_codes"))
    expect(rendered).to include(I18n.t("levels.new.submit"))
    expect(rendered).to include(game_levels_path(game))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
  end
end

RSpec.describe "levels/show", type: :view do
  it "renders a single-question level's code inline" do
    game = create_game
    level = create_level(game: game)

    assign(:game, game)
    assign(:level, level)
    view.define_singleton_method(:logged_in?) { false }

    render

    expect(rendered).to include(level.name)
    expect(rendered).to include(level.text)
    expect(rendered).to include(I18n.t("levels.show.code_label"))
    expect(rendered).to include(level.correct_answer)
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.edit_short")))
    expect(rendered).to include(game_level_question_answers_path(game, level, level.questions.first))
    expect(rendered).to include(I18n.t("hints.list.empty"))
    expect(rendered).to include(delete_game_level_path(game, level))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("levels.show.back_to_game", name: game.name)))
  end

  it "renders each question's code separately when the level has more than one question" do
    game = create_game
    level = create_level(game: game)
    level.questions.build(correct_answer: "SECOND").save!

    assign(:game, game)
    assign(:level, level)
    view.define_singleton_method(:logged_in?) { false }

    render

    expect(rendered).to include(I18n.t("levels.show.codes_label", count: 2))
  end
end
