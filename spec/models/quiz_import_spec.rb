# -*- encoding : utf-8 -*-
require "rails_helper"

# Parses the block format the owner already writes quizzes in -- the same text
# that was loaded into Викторина by a console script on 2026-08-08, because
# the application offered no way to do it. See
# docs/superpowers/specs/2026-08-09-quiz-bulk-import-design.md.
RSpec.describe QuizImport do
  let(:sample) do
    <<~TEXT
      Какая порода собак считается миниатюрным родственником грейхаунда?
      A) Уиппет
      B) Той-терьер
      C) *Левретка
      D) Басенджи
      E) Салюки
      Какое устройство позволяет разговаривать по телефону без удерживания аппарата у уха?
      A) *Гарнитура
      B) Автомагнитола
    TEXT
  end

  it "reads each question with its options in order" do
    parsed = QuizImport.new(sample)

    expect(parsed).to be_valid
    expect(parsed.questions.size).to eq(2)
    expect(parsed.questions.first[:text]).to start_with("Какая порода собак")
    expect(parsed.questions.first[:options].map { |option| option[:text] })
      .to eq(%w[Уиппет Той-терьер Левретка Басенджи Салюки])
  end

  it "marks the asterisked option correct and strips the asterisk" do
    parsed = QuizImport.new(sample)

    correct = parsed.questions.first[:options].select { |option| option[:correct] }

    expect(correct.map { |option| option[:text] }).to eq(["Левретка"])
  end

  # Two asterisks is the checkbox case. The parser only reports how many are
  # correct; Question#single_choice? turns that into radio vs checkbox at
  # render time, and GamePassing#answer_options! requires set equality.
  it "accepts more than one correct option" do
    parsed = QuizImport.new(<<~TEXT)
      Что из этого — города?
      A) *Минск
      B) Ручка
      C) *Тбилиси
    TEXT

    expect(parsed).to be_valid
    expect(parsed.questions.first[:options].count { |option| option[:correct] }).to eq(2)
  end

  it "ignores blank lines between questions" do
    parsed = QuizImport.new("Вопрос?\n\nA) *Да\n\nB) Нет\n")

    expect(parsed).to be_valid
    expect(parsed.questions.first[:options].size).to eq(2)
  end

  # Any letter, not only A-E: a list of six options must not silently lose its
  # sixth.
  it "accepts option letters past E" do
    parsed = QuizImport.new("Вопрос?\nA) *Раз\nB) Два\nF) Шесть\n")

    expect(parsed.questions.first[:options].map { |option| option[:text] })
      .to eq(%w[Раз Два Шесть])
  end

  describe "refusals" do
    it "refuses a question with no correct option, naming the line" do
      parsed = QuizImport.new("Вопрос?\nA) Раз\nB) Два\n")

      expect(parsed).not_to be_valid
      expect(parsed.errors.first).to include("1")
    end

    it "refuses a question with fewer than two options" do
      parsed = QuizImport.new("Вопрос?\nA) *Раз\n")

      expect(parsed).not_to be_valid
    end

    it "refuses option lines that appear before any question" do
      parsed = QuizImport.new("A) *Раз\nB) Два\n")

      expect(parsed).not_to be_valid
      expect(parsed.errors.first).to include("1")
    end

    # An author fixing one error per round-trip is why bulk import stops being
    # faster than the per-level form.
    it "reports every bad question, not just the first" do
      parsed = QuizImport.new("Первый?\nA) Раз\nB) Два\nВторой?\nC) Три\nD) Четыре\n")

      expect(parsed.errors.size).to eq(2)
    end

    # Importing nothing silently would look like it worked.
    it "refuses empty text" do
      expect(QuizImport.new("   \n\n")).not_to be_valid
    end
  end
end
