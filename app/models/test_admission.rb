# -*- encoding : utf-8 -*-
# Permission for someone other than the author to play one TESTING run.
#
# Two shapes, distinguished by user_id rather than by a type column:
#
#   user_id NULL     -- a real team, admitted as itself, playing with its own
#                       members.
#   user_id present  -- one player, admitted alone. team_id then names a
#                       DISPOSABLE team that holds no members and no captain.
#
# The disposable team is not a convenience. users.team_id is a single column
# and Team#adopt_captain writes it, so making a solo tester the captain of a
# fresh team would move them out of their real one and leave it captainless --
# the bricked state the 2026-08-08 team-membership programme exists to remove.
# A team with a passing and no members is strange-looking and correct.
class TestAdmission < ApplicationRecord
  belongs_to :game_run
  belongs_to :team
  belongs_to :user, :optional => true

  scope :of_run, ->(run) { where(:game_run_id => run.id) }
  scope :solo,   ->      { where.not(:user_id => nil) }

  # :on => :create deliberately. Teardown clears is_testing before it sweeps,
  # and a validation firing on every save would make the sweep unable to touch
  # the very rows it exists to remove.
  validate :run_is_testing, :on => :create

  def solo?
    self.user_id.present?
  end

  # The one place a disposable team is created. Transactional because a team
  # without its admission is an orphan nothing will ever sweep: teardown finds
  # disposable teams THROUGH their admissions.
  #
  # Team.create! with only a name, deliberately -- no captain and no members.
  # Team#adopt_captain writes users.team_id, so naming a captain here would
  # move the tester out of their real team. See the class comment.
  def self.admit_player!(run, user)
    transaction do
      team = Team.create!(:name => disposable_team_name(user, run))
      create!(:game_run => run, :team => team, :user => user)
    end
  end

  # Removing the row is NOT enough, and the difference is the whole point of
  # this method. GamePassingsController#find_or_create_game_passing returns an
  # existing passing before it ever calls may_start_passing?, so a tester who
  # has already opened the game keeps playing no matter what this table says.
  # The passing is the live grant; the admission only decides who may get one.
  #
  # Log rows go too, and not merely for tidiness: Team#deletable? refuses a
  # team that still holds one, so a disposable team whose tester answered
  # anything would survive revocation. (finish_test needs no equivalent -- it
  # already deletes the whole run's logs.)
  #
  # Same ordering as GameRun#sweep_test_admissions!: passing and logs first,
  # then the row, then the team.
  def revoke!
    self.class.transaction do
      GamePassing.where(:game_run_id => game_run_id, :team_id => team_id).delete_all
      Log.where(:game_run_id => game_run_id, :team_id => team_id).delete_all

      doomed = solo? ? team : nil
      destroy
      doomed.destroy if doomed && doomed.reload.deletable?
    end
  end

  # teams.name is unique, so this must be collision-proof rather than
  # decorative. Untranslated and ASCII on purpose: it is stored data, read by
  # everyone in the run and shown in its log lines, and an i18n'd name would
  # freeze whichever locale the inviting author happened to be using into a row
  # that outlives their session.
  def self.disposable_team_name(user, run)
    base = "#{user.nickname} (test ##{run.id})"
    return base unless Team.exists?(:name => base)

    (2..10).each do |n|
      candidate = "#{base}-#{n}"
      return candidate unless Team.exists?(:name => candidate)
    end

    raise ArgumentError, "cannot find a free disposable team name for #{base}"
  end

  private

  def run_is_testing
    return if game_run&.is_testing?

    errors.add(:game_run, :not_testing)
  end
end
