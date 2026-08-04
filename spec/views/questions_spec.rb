# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for questions/new.html.erb.
RSpec.describe "questions/new", type: :view do
  it "renders the new-question form" do
    level = create_level
    game = level.game
    question = level.questions.build

    assign(:game, game)
    assign(:level, level)
    assign(:question, question)
    assign(:answer, nil)

    render

    expect(rendered).to include(level.name)
    expect(rendered).to include(game.name)
    expect(rendered).to include(I18n.t("questions.new.code_label"))
    expect(rendered).to include(I18n.t("questions.new.submit"))
    expect(rendered).to include(game_level_questions_path(game, level))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
    expect(rendered).to include(game_level_path(game, level))
  end

  # Merb original reads @answer (not @question) for error_messages_for --
  # a pre-existing quirk (see task-9c-report.md) preserved rather than
  # "fixed": on the failed-answer-save branch of QuestionsController#create,
  # @answer is a validation-carrying instance, which is exactly when this
  # matters.
  it "shows validation errors carried on @answer, per the preserved Merb quirk" do
    level = create_level
    game = level.game
    question = level.questions.build

    bad_answer = Answer.new(level: level, question: question)
    bad_answer.valid?

    assign(:game, game)
    assign(:level, level)
    assign(:question, question)
    assign(:answer, bad_answer)

    render

    expect(rendered).to include(I18n.t("shared.error_header"))
  end
end
