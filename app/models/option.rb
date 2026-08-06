# One choice presented for a quiz question.
#
# Deliberately not an Answer. Answer means "an accepted spelling of the correct
# code" and every row is correct by construction; a row representing a
# deliberately wrong choice would contradict that everywhere, and would put
# distractors in the very table the code-matching path reads. A separate table
# means that path cannot change behaviour at all.
class Option < ApplicationRecord
  include TranslatableContent

  TRANSLATABLE_FIELDS = %w[text].freeze

  belongs_to :question, optional: true

  validates :text, presence: true

  scope :correct, -> { where(:is_correct => true) }

  # Options are author-written content, so a multilingual game must translate
  # them before publication -- see Game#translatable_records.
  def translation_game
    self.question&.level&.game
  end
end
