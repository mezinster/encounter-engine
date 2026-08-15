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

  # The :open context, not :create, and not unconditional. These are the rules
  # for the ACT of opening a run, not for a run's existence -- which is a
  # genuine distinction here, twice over:
  #
  #   * Game declares `has_many :runs, autosave: true`, so every `game.save`
  #     re-validates its runs. An unconditional check would raise on
  #     finish_game!, which saves a game whose starts_at is long past. Phase 1
  #     (D4) left these on Game for exactly this reason.
  #   * on: :create is still too broad. A run whose start date is in the PAST
  #     is a legitimate record -- it is what every finished run is, and what a
  #     spec modelling an earlier cohort has to be able to build.
  #
  # Only Game#open_run! saves in this context, so only an operator opening a
  # run is held to them.
  validates :max_team_number, presence: true,
                              numericality: { greater_than: 0, less_than: 10000 },
                              on: :open
  # A run opened without a start date is accepted by starts_in_the_future
  # below -- it returns early on nil -- and then never starts: Game#started?
  # reads nil as "not yet", so the game sits scheduled for ever, unplayable,
  # while the operator was told the run had opened. An empty datetime-local
  # input submits "", so this is one stray Enter away.
  #
  # registration_deadline is deliberately NOT required: a game with no
  # deadline is a real, existing state (production game 3 has none).
  validates :starts_at, presence: true, on: :open
  validate :starts_in_the_future, on: :open
  validate :deadline_is_before_start, on: :open

  has_many :passings, :class_name => "GamePassing", :foreign_key => "game_run_id"

  # dependent: :destroy so admissions cascade through
  # Game has_many :runs, dependent: :destroy when a game is deleted. Unlike
  # :passings above -- which deliberately carries no dependent: option because
  # a passing is a record of a race somebody ran -- an admission is permission,
  # meaningless once the run it names is gone.
  has_many :test_admissions, :dependent => :destroy

  # Replaces GamePassing.of(team, game). A team has at most one passing per
  # run; in phase 3 it may have one in each of several runs of the same game,
  # which is exactly what the old game-scoped lookup could not express.
  def passing_for(team)
    passings.of_team(team).first
  end

  def finished_teams
    passings.finished.map(&:team)
  end

  # Whether this run's standings may be shown.
  #
  # THE single definition of that rule. It used to exist twice -- once in
  # GamePassingsController's started-run guard, once implicitly in the results
  # switcher, which linked every run unconditionally. They disagreed, so a
  # scheduled rerun appeared as a link that answered 401. Both now read this.
  #
  # The draft check mirrors Game#started?: an unpublished game has not begun
  # whatever the clock says.
  def results_visible?
    return false if game.nil? || game.draft?

    starts_at.present? && Time.now > starts_at
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

  private

  # The messages are looked up from GAME's existing keys rather than new
  # game_run ones: the sentences are identical, they are already translated in
  # all seven locales, and duplicating them would give two strings to keep in
  # step.
  def starts_in_the_future
    return if starts_at.nil? || starts_at > Time.now

    errors.add(:starts_at,
               I18n.t("activerecord.errors.models.game.attributes.starts_at.in_the_past"))
  end

  def deadline_is_before_start
    return if registration_deadline.nil? || starts_at.nil?
    return if registration_deadline <= starts_at

    errors.add(:registration_deadline,
               I18n.t("activerecord.errors.models.game.attributes.registration_deadline.after_game_start"))
  end
end
