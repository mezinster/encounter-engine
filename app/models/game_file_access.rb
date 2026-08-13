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

    @game_file.file_attachments.includes(:attachable).any? { |attachment| visible_to?(passing, attachment) }
  end

  private

  def game = @game_file.game

  def author_or_superadmin?
    return false if game.nil?

    @user.superadmin? || @user.author_of?(game)
  end

  # Resolved BY GAME, and within the game, by RUN. "The user's current
  # passing" would authorise a file in game A using the team's progress in
  # game B; game-scoped alone would authorise it using a DIFFERENT RUN's
  # progress, since a team has one passing per run and may have played this
  # game before. GameRun#passing_for is the established lookup for "this
  # team's passing in this run" -- see the comment on GameRun#passing_for and
  # its other callers (GamePassingsController, GamePassingsHelper,
  # InterventionsController). game.current_run autobuilds an unsaved run
  # rather than returning nil (see its comment); an unsaved run has no
  # persisted passings, so passing_for correctly answers nil there.
  def passing_for_game
    return nil if game.nil?

    team = @user.team
    return nil if team.nil?

    game.current_run.passing_for(team)
  end

  # finished? alone is also true for a passing ended by exit!, which is a
  # team that QUIT mid-course, not one that completed it -- GamePassing#exit!
  # stamps finished_at as well as status "exited". Without the exited? check,
  # a team could exit on level 1 and then fetch every level's file: this is
  # the same threat LogsController#ensure_full_log_access and GamePassing's
  # own `completed` scope guard against, for the same reason.
  def completed?(passing)
    passing.finished? && !passing.exited?
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
    return true  if completed?(passing)

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
    return true  if completed?(passing)

    current = passing.current_level
    return true if current.nil? || level.id != current.id   # a passed level

    # hints_to_show reads current_level_entered_at unconditionally --
    # Hint#ready_to_show? subtracts it from `now`, which raises TypeError on
    # nil rather than returning false. Nil here means "no hint has ever been
    # timed for this passing"; refusing is the safe reading, and it keeps
    # this route's contract (everything not permitted is a 404, never a 500
    # an id-enumerator could distinguish).
    return false if passing.current_level_entered_at.nil?

    passing.hints_to_show.include?(hint)
  end
end
