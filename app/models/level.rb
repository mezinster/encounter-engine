# coding: utf-8
class Level < ApplicationRecord
  include TranslatableContent
  include ChildErrorPromotion
  include FileAttachable

  TRANSLATABLE_FIELDS = %w[name text].freeze

  def translation_game
    self.game
  end

  acts_as_list :scope => :game

  belongs_to :game, optional: true
  has_many :questions, :dependent => :destroy
  has_many :answers, :dependent => :destroy
  has_many :hints, -> { order('delay ASC') }, :dependent => :destroy

  validates :name, presence: true
  validates :text, presence: true
  validates :game, presence: true

  # An empty code on the new-level form used to surface as
  # "Questions имеет неверное значение". Declared after has_many :questions so
  # it runs after the autosave validation it replaces.
  promotes_errors_from :questions

  scope :of_game, ->(game) { where(game_id: game) }

  def next
    lower_item
  end

  def correct_answer=(answer)
    self.questions.build(:correct_answer => answer)
  end

  def correct_answer
    self.questions.empty? ?
      nil :
      self.questions.first.answers.first.value
  end

  def multi_question?
    self.questions.count > 1
  end

  # A level presents options rather than asking for a typed code. Derived, not
  # stored: a level with no options behaves exactly as it always has, through
  # exactly the same code.
  def quiz?
    self.questions.any?(&:quiz?)
  end

  # Stored in seconds, authored in minutes -- mirroring Hint#delay_in_minutes,
  # which authors already use for hint delays on this same form.
  def wrong_answer_penalty_in_minutes
    self.wrong_answer_penalty.to_i / 60
  end

  def wrong_answer_penalty_in_minutes=(value)
    self.wrong_answer_penalty = value.to_i * 60
  end

  # Operator entry points, called by InterventionsController. That controller
  # keeps a standing rule -- "every action calls a named model method ...
  # nothing here writes a column directly" -- and these exist to honour it.
  #
  # update_column, not update!: a level belonging to a running game cannot pass
  # its game's validations (game_starts_in_the_future fires once starts_at is
  # past and author_finished_at is nil), so an ordinary write would 422.
  def allow_any_code!
    update_column(:any_code_passes, true)
  end

  def require_all_codes!
    # "All of nothing" is not a rule a team could satisfy. ArgumentError is the
    # refusal channel InterventionsController already rescues.
    raise ArgumentError, "level has no codes" if questions.empty?

    update_column(:any_code_passes, false)
  end

  # Made consistent with Question#matches_any_answer, which strips both sides
  # before comparing. This path used to skip the strip, relying on
  # GamePassing#check_answer! to strip the submitted value first — that
  # masked the inconsistency in the live flow but left this method unsafe if
  # called directly. See Question#matches_any_answer for why plain
  # String#upcase (rather than the old upcase_utf8_cyr monkey patch) is
  # correct here.
  #
  # Skips quiz questions for the same reason GamePassing#correct_answer? does:
  # a question keeps its Answer rows after options turn it into a quiz
  # question. These two must filter identically -- correct_answer? decides
  # WHETHER a typed answer counts and this decides WHICH question it credits,
  # so a disagreement would mark the wrong question answered.
  def find_question_by_answer(answer_value)
    self.questions.reject(&:quiz?).detect do |question|
      question.answers.any? { |answer| answer.value.to_s.strip.upcase == answer_value.to_s.strip.upcase }
    end
  end
end
