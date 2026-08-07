# -*- encoding : utf-8 -*-
class GameEntry < ApplicationRecord
  belongs_to :game, optional: true
  belongs_to :team, optional: true

  validates :game, presence: true
  validates :team_id, presence: true

  scope :of_game, ->(game) { where(game_id: game.id) }
  scope :of_team, ->(team) { where(team_id: team.id) }
  scope :with_status, ->(status) { where(status: status) }

  # Nothing enforces one entry per team per game (no unique index in
  # db/schema.rb, and GameEntriesController#new creates a fresh row on every
  # hit -- see the controller). A team can end up holding two entries for the
  # same game: an earlier one the author rejected and a later one accepted.
  # Returning `.first` unscoped picked the lowest id -- the rejected row --
  # and locked a legitimately accepted team out of a live game via the
  # find_or_create_game_passing guard. Prefer the accepted entry if one
  # exists; otherwise fall back to whatever is there, unchanged.
  def self.of(team, game)
    scope = of_team(team).of_game(game)
    scope.with_status("accepted").first || scope.first
  end

  def reopen!
    self.status = "new"
    save!
  end

  def accept!
    self.status = "accepted"
    save!
  end

  def reject!
    self.status = "rejected"
    save!
  end

  def recall!
    self.status = "recalled"
    save!
  end

  def cancel!
    self.status = "canceled"
    save!
  end
end
