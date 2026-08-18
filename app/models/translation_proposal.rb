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

  validates :field,  :presence => true
  validates :locale, :presence => true
  # NO presence validation on proposed_text, deliberately. It used to be here,
  # and it rejected exactly the blank output Translation::Flags marks `empty`
  # -- so create! raised RecordInvalid, which is not a Client::Error and so
  # slipped past Runner#translate's rescue into Runner#call's `rescue
  # StandardError`, failing the WHOLE run and abandoning every remaining unit.
  # Hint#text has no presence validation either, so a blank source is
  # reachable and the failure was deterministic on retry. The design lists
  # `empty` among the five checks precisely so a human sees it; a validation
  # that makes the flag unreachable deletes the feature it was guarding.
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

  # What the flagged bulk button acts on, and what its label counts. One
  # predicate for both, deliberately: the count IS that button's confirmation
  # step -- there is no dialog, this app has no rails-ujs -- so a label that
  # could disagree with the action would be worse than no label at all. A SQL
  # scope beside this Ruby predicate would be exactly that second definition
  # (`flags = " "` is flagged to `!= ''` and unflagged to #flag_list).
  #
  # `empty` is excluded, not swept: TranslationProposalsController#accept
  # refuses blank text outright -- "Reject is how you say no; blank is a
  # mistake, and it says so" -- and ContentTranslation has no presence
  # validation on `value`, so accepting one writes a blank row that the
  # proposal can never be taken back out of. Blank output is not something a
  # reviewer can read and decide is fine, which is what this button is for.
  def bulk_acceptable_flagged?
    self.state == PENDING && self.flagged? && !self.flag_list.include?("empty")
  end

  # What actually reached (or would reach) content_translations. proposed_text
  # stays immutable so the table can still answer "what did the machine
  # produce"; accepted_text records the reviewer's edit when there was one.
  def final_text
    self.accepted_text.nil? ? self.proposed_text : self.accepted_text
  end

  # True only when a human changed the words. Absence of accepted_text means
  # accepted verbatim, not "not accepted" -- state says that.
  def edited?
    !self.accepted_text.nil? && self.accepted_text != self.proposed_text
  end
end
