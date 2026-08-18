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

  # "Which admissions does this person hold?" -- and it must ask about BOTH
  # shapes, because the two are stored in different columns and a reader that
  # remembers only one is wrong for exactly half the people it serves.
  #
  # That is not hypothetical. shared/_test_runs.html.erb, the dashboard block
  # whose entire job is giving a tester somewhere to click, matched on user_id
  # alone -- so it listed every solo tester's run and no team's, and two teams
  # admitted to a real test run could not find the game anywhere. Reported
  # 2026-08-15. Every other reader on the path (ensure_author_if_game_is_testing,
  # may_start_passing?) already handled both, which is why the game page and the
  # play screen answered 200 to people the dashboard showed nothing.
  #
  # A method rather than a scope because the team clause has to disappear
  # entirely when the user has no team. `where(:team_id => nil)` would not do:
  # it is a live condition matching any admission whose team_id IS NULL, not an
  # absent one.
  #
  # Be honest about what that guard is worth today: team_id is NOT NULL and
  # belongs_to :team is required, so no such row can exist and the unguarded
  # form behaves identically. Mutation-tested, and removing the guard leaves
  # the suite green -- deliberately recorded here rather than papered over with
  # a test that cannot fail. The guard is kept because it costs one line and
  # states the intent ("this person has no team, so no team matches") in a form
  # that stays correct if the column ever becomes nullable. It is not load-
  # bearing now, and a future reader deleting it will not break anything.
  #
  # `.or` requires both sides to differ only in their where clauses, which two
  # bare `where`s on the same model satisfy.
  def self.held_by(user)
    scope = where(:user_id => user.id)
    return scope if user.team_id.blank?

    scope.or(where(:team_id => user.team_id))
  end

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
  # Ledger rows go too, and BEFORE the passings that identify them --
  # Team#deletable? refuses on point_transactions as well, so a tester who
  # earned anything would otherwise survive revocation exactly as one who
  # answered anything would, and the row would be left orphaned with nothing
  # in any UI able to reach it. An append-only ledger may still lose rows
  # here: append-only means it is never REVERSED (no compensating entry, no
  # edit -- see PointTransaction's class comment), not that a row outlives the
  # attempt it describes. start_test can turn an already-running REAL run into
  # a testing one, so these are not always zero-value rehearsal rows. See the
  # whole-branch review, F3, and the matching deletion in
  # GamesController#finish_test.
  #
  # Same ordering as GameRun#sweep_test_admissions!: transactions, passings
  # and logs first, then the row, then the team -- deletable? is consulted
  # after all of them, deliberately.
  def revoke!
    self.class.transaction do
      passings = GamePassing.where(:game_run_id => game_run_id, :team_id => team_id)
      PointTransaction.where(:game_passing_id => passings.select(:id)).delete_all
      passings.delete_all
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
