# -*- encoding : utf-8 -*-
#
# Parses the block format the owner already writes quizzes in:
#
#   Вопрос?
#   A) Вариант
#   B) *Правильный вариант
#
# A line that is not an option line starts a new question. A leading * marks a
# correct option. Any single letter is accepted as a label, not only A-E, so a
# list running past E does not silently lose its tail.
#
# Deliberately knows nothing about the database: it turns text into a
# structure and reports what it could not read, so the whole of the format's
# surface is testable without fixtures. QuizImport::Writer does the writing.
class QuizImport
  OPTION_LINE = /\A(?<label>[[:alpha:]])\)\s*(?<text>.+)\z/

  attr_reader :questions, :errors

  def initialize(text)
    @questions = []
    @errors = []
    parse(text.to_s)
  end

  def valid?
    errors.empty?
  end

  private

  def parse(text)
    current = nil
    previous_was_option = false

    text.each_line.with_index(1) do |raw, number|
      line = raw.strip
      next if line.empty?

      if (match = OPTION_LINE.match(line))
        if current.nil?
          add_error(number, :option_before_question)
          next
        end

        option_text = match[:text].strip
        current[:options] << { :text => option_text.sub(/\A\*\s*/, ""),
                               :correct => option_text.start_with?("*") }
        previous_was_option = true
      else
        # A text line CONTINUES the block it is in unless an option line has
        # already been seen for that block. That is what lets a quest task run
        # to several lines, and it is also why every paste written before this
        # change parses identically: those have one-line questions, so every
        # text line in them follows an option line and still starts a block.
        #
        # Blank lines are skipped above and therefore do not separate blocks
        # either -- a paste with spaced-out paragraphs must not fragment.
        if current.nil? || previous_was_option
          current = { :text => line, :options => [], :line => number }
          @questions << current
        else
          current[:text] = "#{current[:text]}\n#{line}"
        end
        previous_was_option = false
      end
    end

    assign_modes
    validate_questions
    add_error(1, :empty) if @questions.empty? && @errors.empty?

    # The line number is scaffolding for error messages, not part of the
    # parsed shape the writer consumes.
    @questions.each { |question| question.delete(:line) }
  end

  # One option line is a code, two or more is a choice. Derived here rather
  # than in the writer so the whole of the format's surface stays testable
  # without fixtures.
  #
  # A block with NO options is labelled :quiz and rejected a moment later by
  # validate_questions. The label is never read, because an invalid paste never
  # reaches the writer.
  def assign_modes
    @questions.each do |question|
      question[:mode] = question[:options].size == 1 ? :quest : :quiz
      question[:code] = question[:options].first[:text] if question[:mode] == :quest
    end
  end

  # Every bad question is reported, not just the first. An author fixing one
  # error per round-trip is why bulk import stops being faster than adding
  # levels one at a time.
  def validate_questions
    @questions.each do |question|
      if question[:options].empty?
        add_error(question[:line], :no_answer_line)
      elsif question[:mode] == :quest
        # A) * parses as an option whose text is "*" and strips to nothing.
        # Caught here rather than at Answer's presence validation, which would
        # raise RecordInvalid inside the import transaction -- a 500 where the
        # author should have got a line number.
        add_error(question[:line], :blank_code) if question[:code].to_s.strip.empty?
      elsif question[:options].none? { |option| option[:correct] }
        add_error(question[:line], :no_correct_option)
      end
    end
  end

  def add_error(line, key)
    @errors << I18n.t("quiz_imports.errors.#{key}", :line => line)
  end
end
