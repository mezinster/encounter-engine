# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe Level, "#find_question_by_answer" do
  it "ignores case for Latin codes" do
    level = create_level(correct_answer: "code1")
    expect(level.find_question_by_answer("CODE1")).to eq(level.questions.first)
  end

  it "ignores case for Cyrillic codes" do
    level = create_level(correct_answer: "код1")
    expect(level.find_question_by_answer("КОД1")).to eq(level.questions.first)
  end

  it "ignores case for Greek codes" do
    level = create_level(correct_answer: "κωδικός")
    expect(level.find_question_by_answer("ΚΩΔΙΚΌΣ")).to eq(level.questions.first)
  end

  it "ignores case for German codes with a sharp s" do
    level = create_level(correct_answer: "straße")
    expect(level.find_question_by_answer("STRASSE")).to eq(level.questions.first)
  end

  it "ignores surrounding whitespace" do
    level = create_level(correct_answer: "code1")
    expect(level.find_question_by_answer("  code1  ")).to eq(level.questions.first)
  end

  it "returns nil for a genuinely different code" do
    level = create_level(correct_answer: "code1")
    expect(level.find_question_by_answer("code2")).to be_nil
  end
end
