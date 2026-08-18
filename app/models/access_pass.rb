# -*- encoding : utf-8 -*-
# One team's entitlement to one full run of one game.
#
# Both foreign keys are required: a pass is always somebody's. An unredeemed
# access code is NOT a pass -- in sub-project C it is a row in a separate
# table holding a digest, and redeeming it CREATES a pass. That is what keeps
# team_id NOT NULL here forever.
class AccessPass < ApplicationRecord
  SOURCES = %w[operator_invite].freeze

  belongs_to :game
  belongs_to :team
  belongs_to :issued_by, :class_name => "User", :optional => true

  # The 1:1 binding that makes #spent? derivable. game_passings.access_pass_id
  # carries a partial unique index, so this can never find two.
  has_one :attempt, :class_name => "GamePassing", :foreign_key => "access_pass_id"

  validates :source, :inclusion => { :in => SOURCES }
  validate  :game_is_gated, :on => :create

  def revoked?
    self.revoked_at.present?
  end

  # DERIVED, never stored -- see the programme design, P4.
  #
  # The rule is "the TEAM ended the attempt": completing the course spends the
  # pass, quitting spends it, an operator closing the game does not. That rule
  # reduces to one column because GamePassing#exit! sets finished_at as well as
  # the status, while #end! sets status "ended" and leaves finished_at nil.
  #
  # finished_at.present? is today's ENCODING of the rule, not the rule itself.
  # spec/models/access_pass/spent_spec.rb asserts every state, including both
  # operator cases, so a future change to what end! writes fails a test rather
  # than silently spending customers' passes.
  #
  # It also means reinstate! and move_to_level! un-spend a pass for free: both
  # clear finished_at, and there is no second attempt left to redeem because
  # the pass stays bound to this one.
  def spent?
    attempt.present? && attempt.finished_at.present?
  end

  def live?
    !revoked? && !spent?
  end

  # The pass an attempt should consume: oldest first, so a team granted three
  # passes uses them in the order they were issued.
  #
  # Loaded and filtered in Ruby rather than expressed in SQL: liveness depends
  # on the attempt's finished_at through a LEFT JOIN, a team holds a handful of
  # passes at most, and a SQL form would have to restate the encoding above in
  # a second place. Preloads the attempt so the filter is one query, not N.
  def self.next_for(game, team)
    return nil if team.nil?

    where(:game_id => game.id, :team_id => team.id, :revoked_at => nil)
      .includes(:attempt)
      .order(:created_at)
      .detect(&:live?)
  end

  private

  def game_is_gated
    return if game&.pass_required?

    errors.add(:game, :not_gated)
  end
end
