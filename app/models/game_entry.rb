# -*- encoding : utf-8 -*-
class GameEntry < ApplicationRecord
  belongs_to :game, optional: true
  belongs_to :team, optional: true

  validates :game, presence: true
  validates :team_id, presence: true

  scope :of_game, ->(game) { where(game_id: game.id) }
  scope :of_team, ->(team) { where(team_id: team.id) }
  scope :with_status, ->(status) { where(status: status) }

  # db/migrate/20260808070000_add_unique_index_to_game_entries_on_team_and_game.rb
  # stops a team from holding two SIMULTANEOUSLY LIVE ("new"/"accepted")
  # entries for one game, and GameEntriesController#new/#reopen now check for
  # an existing entry before creating or reviving one. That index is
  # deliberately scoped to the live statuses, not a blanket constraint, so
  # this historical shape can still exist and this method still has to
  # handle it: a team can hold an earlier entry the author rejected AND a
  # later one that was accepted -- both on record, only one ever live at a
  # time. Returning `.first` unscoped picked the lowest id -- the rejected
  # row -- and locked a legitimately accepted team out of a live game via the
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
