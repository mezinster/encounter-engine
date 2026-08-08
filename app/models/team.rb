# -*- encoding : utf-8 -*-
class Team < ApplicationRecord
  has_many :game_entries, :class_name => "GameEntry"
  has_many :game_passings, :class_name => "GamePassing"
  has_many :members, :class_name => "User"
  belongs_to :captain, :class_name => "User", optional: true

  validates :name, presence: true, uniqueness: true

  after_save :adopt_captain

  def current_level_in(game)
    game_passing = GamePassing.of(self, game)
    game_passing.try :current_level
  end

  def finished?(game)
    game_passing = GamePassing.of(self, game)
    !! game_passing.try(:finished?)
  end

  # The single operation through which captaincy ever changes.
  #
  # Deliberately has no revoke counterpart: a bare revoke sets captain_id to
  # nil, which is the bricked-team state this whole programme exists to
  # remove -- such a team can never invite, never register for a game and
  # never quit a race it is already in, because every one of those guards
  # asks "are you the captain", which is useless precisely when the captain
  # is the problem.
  #
  # Membership is required rather than merely conventional:
  # features/invitations/send-invitations.feature freezes "a captain is a
  # member of their own team" by refusing a captain who invites themselves as
  # already being a member. Restricting the candidate set to members also
  # makes adopt_captain's overwrite of users.team_id a no-op here, so this
  # cannot steal anyone out of another team.
  #
  # ArgumentError rather than a validation error, matching the refusal style
  # of the GamePassing operator interventions, whose controller rescues it.
  def set_captain!(member)
    raise ArgumentError, "user is not a member of this team" unless members.include?(member)

    update!(:captain => member)
  end

  protected

  def adopt_captain
    unless captain.nil?
      self.members << captain unless members.include?(captain)
    end
  end
end
