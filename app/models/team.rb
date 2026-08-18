# -*- encoding : utf-8 -*-
class Team < ApplicationRecord
  has_many :game_entries, :class_name => "GameEntry"
  has_many :game_passings, :class_name => "GamePassing"
  has_many :access_passes
  has_many :members, :class_name => "User"
  belongs_to :captain, :class_name => "User", optional: true

  # These two are meaningless once the team is gone, so they travel with it
  # rather than blocking deletion. A dangling invitation is not merely untidy:
  # the dashboard renders invitation.to_team.name, so it would break a screen
  # belonging to whoever was invited.
  #
  # game_entries, game_passings, access_passes and logs deliberately have NO
  # dependent: option -- they are records of races other people ran (or paid
  # for), and #deletable? refuses instead. access_passes especially: it is a
  # purchase record, and a silent cascade would destroy it along with the
  # team.
  has_many :invitations, :class_name => "Invitation", :foreign_key => "to_team_id",
                         :dependent => :destroy
  has_many :team_join_requests, :dependent => :destroy

  validates :name, presence: true, uniqueness: true
  validate :captain_is_not_another_teams_member

  after_save :adopt_captain

  # Both keep taking a GAME: the screens that ask know a game, not a run. They
  # resolve its current run, which is the only run a game-id URL can mean.
  def current_level_in(game)
    game_passing = game.current_run.passing_for(self)
    game_passing.try :current_level
  end

  def finished?(game)
    game_passing = game.current_run.passing_for(self)
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

  # Whether this team can be removed outright, rather than left as the inert
  # tombstone D5 produces when a solo captain leaves. Named after
  # Game#deletable?, which asks the same kind of question one level up.
  #
  # Narrow on purpose. Tables carry a team_id; game_entries, game_passings,
  # access_passes and logs -- record races other people ran (or paid for),
  # and deleting those is the same objection that rules out deleting
  # authored games. So a team that ever entered a game, or was ever granted
  # a pass, is never deletable, however empty it is now. Only a team that
  # never played, never held a pass, and now holds nobody can go, which is
  # exactly the tombstone case and nothing else.
  #
  # access_passes is checked here rather than given dependent: :destroy on
  # the association above: it is a purchase record, and this repository's
  # rule for that kind of row is "refuse the deletion", not "cascade it
  # away" -- same reasoning as game_entries/game_passings/logs.
  #
  # Logs are checked by team_id rather than by the legacy name column: the
  # id-based scope is the one Log's own scopes use since the foreign-key work.
  def deletable?
    members.empty? &&
      captain.nil? &&
      game_entries.empty? &&
      game_passings.empty? &&
      access_passes.empty? &&
      Log.where(:team_id => id).empty?
  end

  # True while the team is in a race that is still running for them.
  #
  # Guards captain self-service handover (TeamsController#hand_over): "Сойти
  # с дистанции" is captain-only, so moving the role mid-race moves that
  # button from one player's screen to another's while the run is live, and a
  # new captain who does not understand the state can burn a limited
  # registration slot through Game#reserve_place_for_team! /
  # free_place_of_team!.
  #
  # Deliberately NOT consulted by the superadmin path. The abandoned-captain
  # case is most acute mid-race, because quitting is itself captain-only, so
  # refusing rescue exactly when it is needed would be the wrong trade -- D1
  # of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md.
  #
  # Both clauses are load-bearing, because GamePassing's terminal states are
  # not symmetrical: end! writes status and leaves finished_at nil, while
  # finishing the last level writes finished_at and leaves status nil. Either
  # check alone would call one of those states a live race. exit! writes both.
  #
  # any? over the loaded association rather than a where(...) scope: a team
  # holds a handful of passings at most, the callers already have the team in
  # memory, and a scope would re-query even when preloaded.
  def in_live_race?
    game_passings.any? { |passing| passing.status.nil? && passing.finished_at.nil? }
  end

  protected

  # adopt_captain (below) overwrites users.team_id, so without this a team
  # could take a captain straight out of somebody else's team -- silently,
  # with no error and no notification to the team they were taken from.
  #
  # Refusing the save is deliberately preferred to skipping the adoption:
  # skipping would leave captain_id pointing at a non-member, and
  # User#captain? reads through user.team rather than teams.captain_id, so
  # the two would disagree. That divergence is precisely what makes the weak
  # SecurityFilters#ensure_team_captain guard ("is this user *a* captain")
  # exploitable, so leaving no divergent state is the safer direction.
  #
  # A teamless captain is fine and must stay fine: TeamsController#create
  # assigns a captain who has no team yet, and adopt_captain is what makes
  # the creator a member. spec/controllers/teams/create_spec.rb pins that.
  def captain_is_not_another_teams_member
    return if captain.nil?
    return if captain.team_id.nil? || captain.team_id == id

    errors.add(:captain, :belongs_to_another_team)
  end

  def adopt_captain
    unless captain.nil?
      self.members << captain unless members.include?(captain)
    end
  end
end
