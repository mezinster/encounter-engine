# -*- encoding : utf-8 -*-
class Log < ApplicationRecord
  belongs_to :game, optional: true

  # Named _record because `team` and `level` are already the snapshot columns.
  belongs_to :team_record,  :class_name => "Team",  :foreign_key => "team_id",  :optional => true
  belongs_to :level_record, :class_name => "Level", :foreign_key => "level_id", :optional => true

  scope :of_game, ->(game) { where(game_id: game) }
  scope :of_team, ->(team) { where(team: team.name) }
  scope :of_level, ->(level) { where(level: level.name) }
end
