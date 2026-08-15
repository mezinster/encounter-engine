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

  private

  def run_is_testing
    return if game_run&.is_testing?

    errors.add(:game_run, :not_testing)
  end
end
