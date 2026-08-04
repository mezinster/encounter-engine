# coding: utf-8
require Rails.root.join("lib/ee_strings")

class Level < ApplicationRecord
  acts_as_list :scope => :game

  belongs_to :game, optional: true
  has_many :questions
  has_many :answers
  has_many :hints, -> { order('delay ASC') }

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

  def find_question_by_answer(answer_value)
    self.questions.detect do |question|
      question.answers.any? { |answer| answer.value.to_s.upcase_utf8_cyr == answer_value.to_s.upcase_utf8_cyr }
    end
  end
end
