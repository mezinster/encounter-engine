class Question < ApplicationRecord
  include TranslatableContent

  # Deliberately empty. The `questions` column is vestigial: nothing in this
  # application writes it (the form sets correct_answer, which builds Answer
  # records) and nothing renders it — every view reference is to the `questions`
  # association, not this column. Listing it here would make Game#missing_translations
  # demand a translation for a field no author can reach, permanently blocking any
  # multilingual game that has questions from leaving draft.
  #
  # A question's actual author-facing content is its answer codes, which are
  # shared across languages by design.
  TRANSLATABLE_FIELDS = [].freeze

  def translation_game
    self.level&.game
  end

  belongs_to :level, optional: true

  # No dependent: option here, deliberately -- not an oversight. Every Answer
  # carries its own level_id (Answer#assign_level derives it from
  # question.level on create), so Level's `has_many :answers, dependent:
  # :destroy` already removes an answer when its level is destroyed,
  # regardless of which question it hangs off. Adding dependent: :destroy
  # here would be redundant, not safer.
  has_many :answers

  # dependent: :destroy here, unlike :answers -- an Option hangs off nothing
  # but its question, so nothing else would clean it up. (An Answer carries its
  # own level_id and is already removed by Level's has_many :answers.)
  has_many :options, :dependent => :destroy

  # No mode flag: having options IS being a quiz question. Nothing can
  # disagree with reality about what kind of question this is.
  def quiz?
    self.options.any?
  end

  # Decides radio vs checkbox at render time, so an author marks what is true
  # rather than picking a control.
  def single_choice?
    self.options.correct.count == 1
  end

  def correct_option_ids
    self.options.correct.pluck(:id).sort
  end

  def correct_answer=(answer)
    self.answers.build(:value => answer)
  end

  def correct_answer
    self.answers.empty? ?
      nil :
      self.answers.first.value
  end

  # Stored answer values are stripped on save, so the submitted one is stripped
  # here too. check_answer! already does it for its own path, but this is the
  # single point where a code is actually compared, and players type these on
  # phones where a stray leading or trailing space is easy to introduce.
  #
  # Comparison used to go through lib/ee_strings.rb's upcase_utf8_cyr, a
  # monkey patch backed by the unicode_utils gem. That existed because Ruby
  # 1.9's String#upcase was ASCII-only. Ruby 2.4 made String#upcase fully
  # Unicode-aware, so the gem and the patch were dead weight — native
  # String#upcase is the more multilingual-correct choice, not a riskier one,
  # since answer codes may be authored in any script.
  def matches_any_answer(answer_value)
    self.answers.any? do |answer|
      answer.value.to_s.strip.upcase == answer_value.to_s.strip.upcase
    end
  end
end
