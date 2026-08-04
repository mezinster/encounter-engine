# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for answers/index.html.erb.
RSpec.describe "answers/index", type: :view do
  it "lists existing code variants with delete links and the add-variant form" do
    level = create_level
    game = level.game
    question = level.questions.first
    answer = question.answers.first

    assign(:game, game)
    assign(:level, level)
    assign(:question, question)
    assign(:answers, [answer])
    assign(:answer, Answer.new)

    render

    expect(rendered).to include(level.name)
    expect(rendered).to include(game.name)
    expect(rendered).to include(I18n.t("answers.index.variants_label"))
    expect(rendered).to include(answer.value)
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.delete_short")))
    expect(rendered).to include(delete_game_level_question_answer_path(game, level, question, answer))
    expect(rendered).to include(I18n.t("answers.index.new_variant_label"))
    expect(rendered).to include(I18n.t("answers.index.submit"))
    expect(rendered).to include(game_level_question_answers_path(game, level, question))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
    expect(rendered).to include(game_level_path(game, level))
  end

  it "renders validation errors with the shared error header" do
    level = create_level
    game = level.game
    question = level.questions.first
    answer = question.answers.first

    bad_answer = Answer.new(level: level, question: question)
    bad_answer.valid?

    assign(:game, game)
    assign(:level, level)
    assign(:question, question)
    assign(:answers, [answer])
    assign(:answer, bad_answer)

    render

    expect(rendered).to include(I18n.t("shared.error_header"))
  end
end
