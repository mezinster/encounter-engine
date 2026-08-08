# -*- encoding : utf-8 -*-
class Log < ApplicationRecord
  belongs_to :game, optional: true

  # Named _record because `team` and `level` are already the snapshot columns.
  belongs_to :team_record,  :class_name => "Team",  :foreign_key => "team_id",  :optional => true
  belongs_to :level_record, :class_name => "Level", :foreign_key => "level_id", :optional => true

  scope :of_game,  ->(game)  { where(game_id: game) }

  # id-scoped, with a fallback for rows the backfill could not resolve (a level
  # name that is ambiguous within its own game). Every caller chains of_game
  # first, so the fallback is bounded to one game and cannot reach across games
  # the way the bare name match did. Task 4 removes it once production is
  # confirmed clean.
  scope :of_team,  ->(team) {
    where("logs.team_id = :id OR (logs.team_id IS NULL AND logs.team = :name)",
          :id => team.id, :name => team.name)
  }
  scope :of_level, ->(level) {
    where("logs.level_id = :id OR (logs.level_id IS NULL AND logs.level = :name)",
          :id => level.id, :name => level.name)
  }

  # Idempotent and safe to re-run: only touches rows whose id is still NULL.
  # Returns the counts, which the migration logs -- a silent backfill that
  # resolved nothing would otherwise look identical to one that resolved
  # everything.
  def self.backfill_ids!
    resolved_teams = 0
    resolved_levels = 0
    ambiguous_levels = 0

    find_each do |log|
      if log.team_id.nil?
        matches = Team.where(:name => log.team).limit(2).to_a
        if matches.length == 1
          log.update_column(:team_id, matches.first.id)
          resolved_teams += 1
        end
      end

      next unless log.level_id.nil?

      matches = Level.where(:game_id => log.game_id, :name => log.level).limit(2).to_a
      if matches.length == 1
        log.update_column(:level_id, matches.first.id)
        resolved_levels += 1
      elsif matches.length > 1
        ambiguous_levels += 1
      end
    end

    { :teams => resolved_teams, :levels => resolved_levels, :ambiguous => ambiguous_levels }
  end
end
