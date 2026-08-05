# app/models/admin_action.rb
#
# One administrative change, recorded. Append-only: nothing in this
# application updates or deletes a row, and nothing should be added that does.
# A log its own subject can edit is not a log.
class AdminAction < ApplicationRecord
  belongs_to :actor, :class_name => "User", :optional => true

  validates :action, presence: true

  scope :newest_first, -> { order(:created_at => :desc) }

  # Snapshots the target's name at the moment of the action.
  #
  # This is why target_label exists at all. A deleted game leaves target_id
  # pointing at a row that no longer exists, so without the snapshot the
  # single most important entry an audit trail can hold -- who deleted what --
  # renders as "Game #47": a number nobody can resolve, recording the loss of
  # the very thing that would have explained it.
  #
  # It also means a renamed game's entry says what it was called when the
  # action happened, which is what an audit trail should say.
  def self.label_for(target)
    return nil if target.nil?
    return target.name if target.respond_to?(:name)
    return target.nickname if target.respond_to?(:nickname)

    nil
  end
end
