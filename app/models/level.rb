# coding: utf-8
class Level < ApplicationRecord
  include TranslatableContent

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

  # Made consistent with Question#matches_any_answer, which strips both sides
  # before comparing. This path used to skip the strip, relying on
  # GamePassing#check_answer! to strip the submitted value first — that
  # masked the inconsistency in the live flow but left this method unsafe if
  # called directly. See Question#matches_any_answer for why plain
  # String#upcase (rather than the old upcase_utf8_cyr monkey patch) is
  # correct here.
  def find_question_by_answer(answer_value)
    self.questions.detect do |question|
      question.answers.any? { |answer| answer.value.to_s.strip.upcase == answer_value.to_s.strip.upcase }
    end
  end
end
