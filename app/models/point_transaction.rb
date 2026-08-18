# -*- encoding : utf-8 -*-
# One entry in an append-only points ledger.
#
# Never updated, never reversed. A team that abandons a run keeps what it
# earned and simply never earns the completion award -- see the design, P3/P4.
class PointTransaction < ApplicationRecord
  # D1's two. Sub-project D2 adds the skip fine; an operator adjustment would
  # add another. Both are negative rows in this same table, which is why
  # `amount` is signed.
  REASONS = %w[level_completed game_completed].freeze

  belongs_to :team
  belongs_to :game
  belongs_to :game_passing
  belongs_to :level,      :optional => true
  belongs_to :created_by, :class_name => "User", :optional => true

  validates :amount, :presence => true, :numericality => { :only_integer => true }
  validates :reason, :inclusion => { :in => REASONS }

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
  def self.award!(passing:, reason:, amount:, level: nil)
    create!(:team_id         => passing.team_id,
            :game_id         => passing.game_id,
            :game_passing_id => passing.id,
            :level_id        => level&.id,
            :amount          => amount,
            :reason          => reason)
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
