require Merb.root + '/lib/ee_strings'

class Question < ActiveRecord::Base
  belongs_to :level
  has_many :answers

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
  def matches_any_answer(answer_value)
    self.answers.any? do |answer|
      answer.value.to_s.strip.upcase_utf8_cyr == answer_value.to_s.strip.upcase_utf8_cyr
    end
  end
end
