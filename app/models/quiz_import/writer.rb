# -*- encoding : utf-8 -*-
#
# Turns questions parsed by QuizImport into quiz levels on a game.
#
# The shape produced is deliberately identical to the levels already in
# production: one level per question, named "Вопрос N" continuing the game's
# existing numbering, with a single question, its options, and a vestigial
# answer code. Imported and hand-made levels are then indistinguishable, which
# matters because an author edits both through the same screens.
class QuizImport
  class Writer
    # Whitespace collapsed and case folded, so re-pasting a master list whose
    # spacing drifted does not duplicate the game. Same rule the console
    # script used when this was still a script.
    def self.normalise(text)
      text.to_s.gsub(/\s+/, " ").strip.downcase
    end

    attr_reader :game, :questions

    def initialize(game, questions)
      @game = game
      @questions = questions
    end

    # Questions the game already has, matched on level text.
    def skipped
      @skipped ||= questions.select { |question| existing_texts.include?(self.class.normalise(question[:text])) }
    end

    def to_add
      @to_add ||= questions - skipped
    end

    # One transaction: a failure part-way must leave the game untouched, or an
    # author is left hand-deleting a half-import.
    def import!
      created = []

      Level.transaction do
        start = game.levels.maximum(:position).to_i

        to_add.each_with_index do |question, index|
          created << create_level(question, start + index + 1)
        end
      end

      created
    end

    private

    def existing_texts
      @existing_texts ||= game.levels.map { |level| self.class.normalise(level.text) }
    end

    def create_level(question, number)
      question[:mode] == :quest ? create_quest_level(question, number) : create_quiz_level(question, number)
    end

    # The standard encounter shape. No options at all, which is what makes
    # Question#quiz? false and therefore routes the level through
    # Level#find_question_by_answer -- the same path a hand-made code level
    # takes. Nothing on the play side needed changing for this.
    def create_quest_level(question, number)
      level = game.levels.create!(
        :name => "Уровень #{number}",
        :text => question[:text],
        :any_code_passes => true,
        :wrong_answer_penalty => 0
      )

      level.questions.create!.answers.create!(:value => question[:code])

      level
    end

    def create_quiz_level(question, number)
      level = game.levels.create!(
        :name => "Вопрос #{number}",
        :text => question[:text],
        :any_code_passes => true,
        :wrong_answer_penalty => 0
      )

      record = level.questions.create!

      # Not decoration. Level#correct_answer reads
      # questions.first.answers.first.value with no safe navigation and
      # app/views/levels/show.html.erb renders it, so a quiz level with no
      # answer row 500s the level page. The value itself is never read by the
      # quiz path -- GamePassing#answer_options! compares option ids -- which
      # is why the level number serves as well as anything, and is what the
      # hand-made levels already carry.
      record.answers.create!(:value => number.to_s)

      question[:options].each do |option|
        record.options.create!(:text => option[:text], :is_correct => option[:correct])
      end

      level
    end
  end
end
