# -*- encoding : utf-8 -*-
class Answer < ApplicationRecord
  belongs_to :question, optional: true
  belongs_to :level, optional: true

  before_save :strip_spaces
  before_create :assign_level

  validates :value, presence: true, uniqueness: { scope: :level_id }

  scope :of_question, ->(question) { where(question_id: question.id) }

  protected

  def strip_spaces
    self.value.strip!
  end

  def assign_level
    self.level = self.question.level
  end
end
