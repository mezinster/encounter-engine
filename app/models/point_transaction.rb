# -*- encoding : utf-8 -*-
# One entry in an append-only points ledger.
#
# Never updated, never reversed. A team that abandons a run keeps what it
# earned and simply never earns the completion award -- see the design, P3/P4.
class PointTransaction < ApplicationRecord
  # D1's two, plus D2's fine, plus an operator adjustment. The negative rows
  # are why `amount` is signed.
  REASONS = %w[level_completed game_completed level_skipped adjustment].freeze

  belongs_to :team
  belongs_to :game,         :optional => true
  belongs_to :game_passing, :optional => true
  belongs_to :level,      :optional => true
  belongs_to :created_by, :class_name => "User", :optional => true

  validates :amount, :presence => true, :numericality => { :only_integer => true }
  validates :reason, :inclusion => { :in => REASONS }

  # belongs_to's automatic presence validation is gone now that both
  # associations are :optional => true (a global adjustment has neither), so
  # it is reinstated here for every other reason -- D1 and D2 rows still need
  # a game and an attempt.
  validates :game,         :presence => true, :unless => :adjustment?
  validates :game_passing, :presence => true, :unless => :adjustment?

  # Both conditional on the reason: every row D1 and D2 write has no note, and
  # a zero-amount award is legitimate (a game scoring 0 per level still records
  # that the level was passed).
  validates :note,   :presence => true,                            :if => :adjustment?
  validates :amount, :numericality => { :other_than => 0 },        :if => :adjustment?

  def adjustment?
    self.reason == "adjustment"
  end

  # Writes the row, or returns nil when one already exists for this
  # (attempt, level, reason).
  #
  # The duplicate is caught by the database, not by an `exists?` check: two
  # concurrent requests both pass a Ruby check and both insert. RecordNotUnique
  # here means the award is already recorded, which is exactly the outcome
  # wanted -- so it is rescued and nothing else is.
  #
  # team_id and game_id are denormalised from the passing so the chart and the
  # per-team history can aggregate without joining through game_passings.
  #
  # This rescue assumes each `create!` owns its own transaction. On
  # PostgreSQL, a unique violation aborts the enclosing transaction, not just
  # the statement -- Rails' implicit save transaction is `requires_new:
  # false`, so it is not a savepoint and simply joins whatever is already
  # open. Called from inside a caller's `transaction do`, the rescued
  # RecordNotUnique here would leave that outer transaction poisoned, taking
  # the next statement in it down too -- including a second `award!` call, or
  # the already-saved level pass, if either shares the transaction. SQLite has
  # no aborted-transaction state, so this stays green in dev and test either
  # way and only breaks in production. See the same trap, played out for real,
  # at `GameFileUpload#save_with_collision_retry`
  # (app/models/game_file_upload.rb:345-357). Task 3's call site
  # (`GamePassing#pass_level!`) is safe today -- nothing wraps it in a
  # transaction -- but any future caller that does must not rescue this
  # method's `nil` from inside one.
  def self.award!(passing:, reason:, amount:, level: nil, created_by: nil)
    create!(:team_id         => passing.team_id,
            :game_id         => passing.game_id,
            :game_passing_id => passing.id,
            :level_id        => level&.id,
            :amount          => amount,
            :reason          => reason,
            :created_by      => created_by)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # NOT award!, and the difference is the point. award! rescues
  # RecordNotUnique and returns nil, which is what makes an award idempotent --
  # a level re-passed after an operator sent a team back awards once. Two
  # deliberate -50s are two different events, not a retry of one.
  #
  # After the index change above a violation cannot fire here at all, and that
  # is exactly what would make reusing award! dangerous rather than harmless:
  # this method would carry a rescue that is currently unreachable and would
  # silently swallow a real constraint error the day anything about that index
  # changes.
  #
  # passing nil => a global row: game_id and game_passing_id both NULL, and the
  # row belongs to the team rather than to any run.
  def self.adjust!(team:, amount:, note:, actor:, passing: nil)
    create!(:team_id         => team.id,
            :game_id         => passing&.game_id,
            :game_passing_id => passing&.id,
            :level_id        => nil,
            :amount          => amount,
            :reason          => "adjustment",
            :note            => note,
            :created_by      => actor)
  end
end
