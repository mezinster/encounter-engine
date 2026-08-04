# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe Question, "#matches_any_answer" do
  def question_with(code)
    level = create_level(correct_answer: code)
    level.questions.first
  end

  it "ignores case for Latin codes" do
    expect(question_with("code1").matches_any_answer("CODE1")).to be true
  end

  it "ignores case for Cyrillic codes" do
    expect(question_with("код1").matches_any_answer("КОД1")).to be true
  end

  it "ignores case for Greek codes" do
    expect(question_with("κωδικός").matches_any_answer("ΚΩΔΙΚΌΣ")).to be true
  end

  it "ignores case for German codes with a sharp s" do
    expect(question_with("straße").matches_any_answer("STRASSE")).to be true
  end

  it "ignores surrounding whitespace" do
    expect(question_with("code1").matches_any_answer("  code1  ")).to be true
  end

  it "still rejects a genuinely different code" do
    expect(question_with("code1").matches_any_answer("code2")).to be false
  end
end
