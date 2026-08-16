# app/models/translation_proposal.rb
#
# One field, translated by the model and not yet accepted. Accepting writes a
# ContentTranslation through the same setter the authoring form uses, so the
# stored row is byte-identical to a hand-typed one; the provenance lives here
# and the game never reads this table.
class TranslationProposal < ApplicationRecord
  belongs_to :translation_run
  belongs_to :translatable, :polymorphic => true
  belongs_to :reviewed_by, :class_name => "User", :optional => true

  PENDING  = "pending".freeze
  ACCEPTED = "accepted".freeze
  REJECTED = "rejected".freeze

  validates :field,         :presence => true
  validates :locale,        :presence => true
  validates :proposed_text, :presence => true
  validates :state, :inclusion => { :in => [ PENDING, ACCEPTED, REJECTED ] }

  scope :pending,   -> { where(:state => PENDING) }
  scope :unflagged, -> { where(:flags => [ nil, "" ]) }

  def flag_list
    self.flags.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def flag_list=(list)
    self.flags = Array(list).map(&:to_s).join(",")
  end

  def flagged?
    self.flag_list.any?
  end
end
