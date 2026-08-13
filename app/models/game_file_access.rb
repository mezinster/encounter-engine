# -*- encoding : utf-8 -*-
#
# The §4 authorization matrix from
# docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md.
#
# A plain object rather than controller filters, for two reasons. It is the
# security contract, so it is worth testing without an HTTP round trip; and
# phase 3B's play screen needs the same answer BEFORE rendering, to decide
# whether a strip appears at all -- a view that renders <img> tags the
# delivery route will 404 is worse than one that renders nothing.
class GameFileAccess
  def initialize(user, game_file)
    @user = user
    @game_file = game_file
  end

  def permitted?
    return false if @user.nil? || @game_file.nil?
    return true  if author_or_superadmin?

    passing = passing_for_game
    return false if passing.nil?

    @game_file.file_attachments.any? { |attachment| visible_to?(passing, attachment) }
  end

  private

  def game = @game_file.game

  def author_or_superadmin?
    return false if game.nil?

    @user.superadmin? || @user.author_of?(game)
  end

  # Resolved BY GAME. "The user's current passing" would authorise a file in
  # game A using the team's progress in game B.
  def passing_for_game
    return nil if game.nil?

    team = @user.team
    return nil if team.nil?

    GamePassing.find_by(:game_id => game.id, :team_id => team.id)
  end

  def visible_to?(passing, attachment)
    case attachment.attachable
    when Level then level_visible?(passing, attachment.attachable)
    when Hint  then hint_visible?(passing, attachment.attachable)
    else false   # fail closed: an attachable type we do not recognise is not visible
    end
  end

  # Finished: every level, because the results and log screens show past
  # levels and the team has completed all of them. Otherwise: the current
  # level and everything at or before it in position order.
  def level_visible?(passing, level)
    return false unless level.game_id == game.id
    return true  if passing.finished?

    current = passing.current_level
    return false if current.nil?

    level.position <= current.position
  end

  # A hint is visible only on the level the team is ON, and only once it has
  # fired. On a PASSED level every hint is visible: the team completed it, so
  # its hints can no longer tell them anything they still need.
  def hint_visible?(passing, hint)
    level = hint.level
    return false if level.nil?
    return false unless level_visible?(passing, level)
    return true  if passing.finished?

    current = passing.current_level
    return true if current.nil? || level.id != current.id   # a passed level

    passing.hints_to_show.include?(hint)
  end
end
