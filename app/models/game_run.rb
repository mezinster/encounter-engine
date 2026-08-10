# -*- encoding : utf-8 -*-
#
# One running of a game. A Game is the CONTENT -- name, description, levels,
# hints, questions, locales -- and a GameRun is one event over that content:
# when it starts, how many teams it takes, when the author ended it.
#
# Phase 1 creates these only by backfill and by Game's autobuild, and nothing
# reads game_run_id on passings or entries yet; results, logs and stats stay
# game-scoped until phase 2.
#
# No schedule validations here yet, deliberately. They stay on Game through
# phase 1 (see the design, D4) because moving them would push each error from
# its own form field to :base and rename four message keys across seven locale
# files -- in a phase whose entire point is that nothing changes. A run first
# becomes creatable without a game form in front of it in phase 3, and that is
# when it needs its own.
class GameRun < ApplicationRecord
  # optional: true plus an explicit presence validation, matching Game's own
  # belongs_to :author -- the established shape in this codebase.
  #
  # inverse_of: :runs is added here at the same time as Game's has_many, not
  # before it: Rails resolves the named inverse eagerly and raises
  # InverseOfAssociationNotFoundError if the other side does not exist yet.
  # It is not merely a nicety once both sides are declared -- Game's has_many
  # carries a scope (-> { order(:ordinal) }) and its name does not match this
  # class, and each of those independently defeats Rails' automatic inverse
  # detection. Without it an autobuilt run on an unsaved game cannot see its
  # parent, and the presence validation below fails on every new game.
  belongs_to :game, :optional => true, :inverse_of => :runs

  validates :game, presence: true
  validates :ordinal, presence: true,
                      numericality: { greater_than: 0 },
                      uniqueness: { scope: :game_id }

  has_many :passings, :class_name => "GamePassing", :foreign_key => "game_run_id"

  # Replaces GamePassing.of(team, game). A team has at most one passing per
  # run; in phase 3 it may have one in each of several runs of the same game,
  # which is exactly what the old game-scoped lookup could not express.
  def passing_for(team)
    passings.of_team(team).first
  end

  def finished_teams
    passings.finished.map(&:team)
  end

  # Ranks on finish time PLUS accrued penalty, so a team that guessed its way
  # to an early finish places behind one that took longer and did not. Without
  # this, quiz penalties would be recorded and never cost anyone a place.
  #
  # Compared in Ruby rather than SQL: expressing "finished_at + penalty_seconds"
  # as a portable interval across SQLite and PostgreSQL is more trouble than it
  # is worth for a listing of tens of teams.
  #
  # Scoped to THIS run. Game-scoped ranking compared absolute timestamps across
  # every cohort that ever played, so a team playing months later always placed
  # last however fast it was -- the defect this whole programme exists to fix.
  # Ranking WITHIN a run is still absolute-time, which is unchanged behaviour.
  def place_of(team)
    passing = passing_for(team)
    return nil unless passing and passing.finished?

    mine = passing.effective_finished_at
    earlier = passings.finished.count do |other|
      other.effective_finished_at < mine
    end
    earlier + 1
  end
end
