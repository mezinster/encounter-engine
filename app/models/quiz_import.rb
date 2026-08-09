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
      else
        current = { :text => line, :options => [], :line => number }
        @questions << current
      end
    end

    validate_questions
    add_error(1, :empty) if @questions.empty? && @errors.empty?

    # The line number is scaffolding for error messages, not part of the
    # parsed shape the writer consumes.
    @questions.each { |question| question.delete(:line) }
  end

  # Every bad question is reported, not just the first. An author fixing one
  # error per round-trip is why bulk import stops being faster than adding
  # levels one at a time.
  def validate_questions
    @questions.each do |question|
      add_error(question[:line], :too_few_options) if question[:options].size < 2
      add_error(question[:line], :no_correct_option) if question[:options].none? { |o| o[:correct] }
    end
  end

  def add_error(line, key)
    @errors << I18n.t("quiz_imports.errors.#{key}", :line => line)
  end
end
