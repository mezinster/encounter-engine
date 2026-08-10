# -*- encoding : utf-8 -*-
class Log < ApplicationRecord
  belongs_to :game, optional: true

  # Named _record because `team` and `level` are already the snapshot columns.
  belongs_to :team_record,  :class_name => "Team",  :foreign_key => "team_id",  :optional => true
  belongs_to :level_record, :class_name => "Level", :foreign_key => "level_id", :optional => true

  scope :of_game,  ->(game)  { where(game_id: game.id) }

  # Plain id matching. This used to fall back to a name match
  # (logs.team_id IS NULL AND logs.team = :name) for rows the backfill
  # (.backfill_ids!) could not resolve. It was removed once production
  # confirmed there was nothing left for it to protect: zero Log rows, zero
  # level names ambiguous within their own game, and zero duplicate team
  # names (checked 2026-08-08, see
  # .superpowers/sdd/2026-08-08-log-foreign-keys/task-4-report.md). Rows
  # written between that check and deploy are resolved by the Task 2
  # backfill, which db:prepare runs before puma starts. A row whose id is
  # still NULL now simply does not match -- it silently drops out of the
  # author's log views instead of falling back to a name lookup.
  scope :of_team,  ->(team)  { where(team_id: team.id) }
  scope :of_level, ->(level) { where(level_id: level.id) }

  scope :of_run, ->(run) { where(:game_run_id => run.id) }

  # Idempotent and safe to re-run: only touches rows whose game_run_id is
  # still NULL. Returns the count, which the migration logs -- a backfill that
  # resolved nothing would otherwise look identical to one that resolved
  # everything, which is why backfill_ids! below reports too.
  #
  # Resolves from game_id ALONE, because today every log of a game belongs to
  # that game's only run. That is exactly correct now and would be ambiguous
  # once a second run exists -- which is the whole reason this column is being
  # stored rather than the join being written into the log views.
  def self.backfill_run_ids!
    resolved = 0

    where(:game_run_id => nil).where.not(:game_id => nil).find_each do |log|
      run = GameRun.where(:game_id => log.game_id).order(:ordinal).last
      next if run.nil?

      log.update_column(:game_run_id, run.id)
      resolved += 1
    end

    { :resolved => resolved }
  end

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
