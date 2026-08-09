# -*- encoding : utf-8 -*-
require "rails_helper"

# Turns parsed questions into levels. Deliberately produces the same shape as
# the 71 levels already in Викторина, so imported and hand-made levels stay
# indistinguishable. See
# docs/superpowers/specs/2026-08-09-quiz-bulk-import-design.md.
RSpec.describe QuizImport::Writer do
  let(:game) { create_game }

  def question(text, *options)
    { :text => text,
      :options => options.map { |option|
        { :text => option.sub(/\A\*/, ""), :correct => option.start_with?("*") }
      } }
  end

  describe "computing what will happen, without writing" do
    it "counts everything as new for an empty game" do
      writer = QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет") ])

      expect(writer.to_add.size).to eq(1)
      expect(writer.skipped).to be_empty
    end

    it "skips a question the game already has, matching on text" do
      create_level(:game => game, :name => "Вопрос 1", :text => "Раз?")
      writer = QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет"),
                                              question("Два?", "*Да", "Нет") ])

      expect(writer.skipped.map { |q| q[:text] }).to eq(["Раз?"])
      expect(writer.to_add.map { |q| q[:text] }).to eq(["Два?"])
    end

    # Same normalisation the console script used, so re-pasting a master list
    # whose spacing drifted does not duplicate the game.
    it "matches regardless of case and surrounding whitespace" do
      create_level(:game => game, :name => "Вопрос 1", :text => "Раз?")
      writer = QuizImport::Writer.new(game, [ question("  РАЗ?  ", "*Да", "Нет") ])

      expect(writer.skipped.size).to eq(1)
    end

    it "writes nothing while computing" do
      writer = QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет") ])

      expect { writer.to_add }.not_to change(Level, :count)
    end
  end

  describe "#import!" do
    it "appends levels numbered on from the game's existing ones" do
      create_level(:game => game, :name => "Вопрос 1", :text => "Старый")

      QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет") ]).import!

      level = game.levels.reload.order(:position).last
      expect(level.name).to eq("Вопрос 2")
      expect(level.position).to eq(2)
      expect(level.text).to eq("Раз?")
    end

    it "gives each level the quiz shape the hand-made ones have" do
      QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет") ]).import!

      level = game.levels.reload.first
      expect(level.any_code_passes).to be true
      expect(level.wrong_answer_penalty).to eq(0)
      expect(level.questions.count).to eq(1)
    end

    it "creates the options in pasted order with the asterisked one correct" do
      QuizImport::Writer.new(game, [ question("Раз?", "Нет", "*Да", "Может") ]).import!

      options = game.levels.reload.first.questions.first.ordered_options
      expect(options.map(&:text)).to eq(%w[Нет Да Может])
      expect(options.select(&:is_correct).map(&:text)).to eq(["Да"])
    end

    # Two asterisks is the checkbox case, decided at render time.
    it "produces a multiple-choice question when two options are correct" do
      QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет", "*Может") ]).import!

      question_record = game.levels.reload.first.questions.first
      expect(question_record.quiz?).to be true
      expect(question_record.single_choice?).to be false
    end

    # THE end-to-end one. Level#correct_answer reads
    # questions.first.answers.first.value with no safe navigation, and
    # app/views/levels/show.html.erb renders it -- so a quiz level with no
    # Answer row 500s the level page. Asserting the row exists would pass with
    # a nil value; this asserts the property that actually matters.
    it "leaves every level's correct_answer readable rather than raising" do
      QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет"),
                                     question("Два?", "*Да", "Нет") ]).import!

      game.levels.reload.each do |level|
        expect { level.correct_answer }.not_to raise_error
      end
    end

    it "skips duplicates and reports what it did" do
      create_level(:game => game, :name => "Вопрос 1", :text => "Раз?")

      created = QuizImport::Writer.new(game, [ question("Раз?", "*Да", "Нет"),
                                               question("Два?", "*Да", "Нет") ]).import!

      expect(created.size).to eq(1)
      expect(game.levels.reload.count).to eq(2)
    end

    # One transaction: a failure part-way must leave the game untouched, or an
    # author is left hand-deleting a half-import.
    it "creates nothing at all when one level fails" do
      questions = [ question("Раз?", "*Да", "Нет"), question("Два?", "*Да", "Нет") ]
      writer = QuizImport::Writer.new(game, questions)
      allow_any_instance_of(Option).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(Option.new))

      expect { writer.import! rescue nil }.not_to change(Level, :count)
    end
  end
end
