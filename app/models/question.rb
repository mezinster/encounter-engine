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

  # At least one CORRECT option, not merely any option. An author who adds a
  # distractor first, or who never ticks a correct one, would otherwise create
  # a question nobody can answer -- the level would render as a quiz and accept
  # no selection, bricking the game. Failing back to the code question is the
  # safe direction.
  #
  # any?(&:is_correct) over the loaded association, deliberately NOT
  # options.correct.any? -- a scope re-queries even when preloaded, which is
  # one of the N+1s already fixed on this branch.
  def quiz?
    self.options.any?(&:is_correct)
  end

  # Decides radio vs checkbox at render time, so an author marks what is true
  # rather than picking a control.
  #
  # Counted in Ruby over the loaded association, NOT `options.correct.count`.
  # A scope-plus-count issues a fresh query even when options are already
  # preloaded, so the play view would fire one per question -- which is exactly
  # what the query-count guard in spec/requests/translated_level_spec.rb caught.
  def single_choice?
    self.options.count(&:is_correct) == 1
  end

  # Same reasoning: select over the loaded association rather than a pluck,
  # which would always hit the database.
  def correct_option_ids
    self.options.select(&:is_correct).map(&:id).sort
  end

  # Author-defined display order, sorted in Ruby so a preloaded association is
  # actually used. `options.order(...)` would re-query.
  def ordered_options
    self.options.sort_by { |option| [ option.position || 0, option.id ] }
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
