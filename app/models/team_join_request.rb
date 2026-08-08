# -*- encoding : utf-8 -*-
#
# A user asking a team's captain to let them in -- the user -> captain
# direction. Deliberately not an Invitation: that model is captain -> user,
# keyed by recepient_nickname, and it validates
# recepient_is_not_member_of_any_team, a refusal three frozen scenarios in
# features/invitations/send-invitations.feature pin. Reusing it for transfer
# would mean relaxing exactly the rule they freeze.
#
# Status vocabulary mirrors GameEntry, which is the app's existing
# request/approve shape.
class TeamJoinRequest < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :team, optional: true

  validates :user, presence: true
  validates :team, presence: true

  scope :pending, -> { where(:status => "new") }
  scope :of_user, ->(user) { where(:user_id => user.id) }
  scope :to_team, ->(team) { where(:team_id => team.id) }

  def pending?
    self.status == "new"
  end

  def accept!
    self.status = "accepted"
    save!
  end

  def reject!
    self.status = "rejected"
    save!
  end
end
