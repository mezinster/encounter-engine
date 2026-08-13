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
#
# This class does NOT read a FileAttachment's locale at all, and that is
# deliberate scope, not an oversight: an attachment's locale slot governs
# which player RENDERS it (FileAttachable#attached_files_for(locale), asked
# by the play screen and the poller, only reads the neutral slot plus the
# player's own), never whether that player is AUTHORIZED to fetch it. So a
# file living only in level 1's "en" slot is correctly absent from a `ru`
# player's rendered strip, but is served a plain 200 if that player's
# browser requests it directly through the delivery route by id -- the same
# level/hint visibility answer any OTHER file on level 1 would get,
# regardless of locale. That is consistent with the rest of this class's
# design (visibility is scoped by LEVEL and by RUN, never by anything
# finer-grained within a level), not a privilege escalation -- every file in
# a slot for a level/hint a team can see was authored for that SAME game by
# its author, who could put it in any locale's slot or none. Pinned in
# spec/models/game_file_access_spec.rb ("permits a file regardless of which
# locale slot it sits in") so a future change to either half of this split
# is a deliberate decision, not a gap nobody noticed.
class GameFileAccess
  # :run -- optional, a GameRun (never an id/ordinal: resolving one from a raw
  # parameter is the CALLER's job, e.g. FileDeliveriesController#requested_run
  # -- so this class only ever handles an object already scoped to a real
  # row). Phase 3B: a past-run log/results screen already knows which run it
  # is showing (LogsController#find_run / GamePassingsController#find_run),
  # and passes it here so visibility is decided against THAT run's passing
  # instead of always "current". nil (the default) keeps every pre-3B caller
  # -- the live play screen, the delivery route with no ?run= -- working
  # exactly as before: resolved_run below reads nil as "game.current_run".
  #
  # Passing a run object here is NOT the same as trusting it: see
  # passing_for_game/resolved_run below. The run only ever gets to ask ITS
  # OWN passing_for(team) -- if the team has none there, this denies exactly
  # as it would for a team with no current-run passing.
  def initialize(user, game_file, run: nil)
    @user = user
    @game_file = game_file
    @run = run
  end

  def permitted?
    return false if @user.nil? || @game_file.nil?
    return true  if author_or_superadmin?

    passing = passing_for_game
    return false if passing.nil?

    # includes(:attachable) batches the polymorphic load by type instead of
    # one query per attachment.
    #
    # NOTE FOR PHASE 3B: calling .includes on the association DISCARDS an
    # already-loaded cache, so this re-queries file_attachments even when the
    # caller preloaded them. Harmless here -- the delivery controller loads one
    # file per request -- but 3B's play screen calls permitted? once per file
    # on a page it will want to preload, and would pay a query per file for the
    # privilege. Read the preloaded association there rather than re-scoping it.
    #
    # Still one query per HINT attachment, for hint.level inside hint_visible?.
    # Bounded by the attachments on a single file; left as is.
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
  # InterventionsController).
  #
  # WHICH run: resolved_run below -- either the caller's explicit :run
  # (Phase 3B, a past-run log/results screen) or, when none was given,
  # game.current_run, same as before Phase 3B existed. game.current_run
  # autobuilds an unsaved run rather than returning nil (see its comment); an
  # unsaved run has no persisted passings, so passing_for correctly answers
  # nil there.
  def passing_for_game
    return nil if game.nil?

    team = @user.team
    return nil if team.nil?

    run = resolved_run
    return nil if run.nil?

    passing = run.passing_for(team)

    # Belt and braces on the run lookup above. A passing reached through
    # a resolved run should already belong to this game, so this can only
    # fire on a corrupted row -- but the two Critical holes this file has
    # already shipped were BOTH "the right-looking lookup returned a passing
    # from somewhere else", and neither announced itself. The cost of
    # re-asserting the thing we just navigated by is one comparison.
    return nil unless passing&.game_id == game.id

    passing
  end

  # The run passing_for_game asks for ITS passing_for(team) -- never trusted
  # past that. A caller-supplied @run (Phase 3B) still has to answer THIS
  # team's own passing_for(team) query above; if the team has no passing in
  # the named run, passing_for returns nil there exactly as game.current_run
  # would for a team with no live passing, and permitted? denies. Naming a
  # run is "which run may answer", never "grant regardless of whether this
  # team actually played it".
  #
  # game_id re-check for the same reason passing_for_game re-checks its own
  # result: an explicitly-passed run is exactly the kind of "looks correctly
  # scoped" input the class's Critical-hole history (see passing_for_game's
  # comment) warns about. In normal use @run is always resolved scoped to
  # this game already (FileDeliveriesController#requested_run does
  # `file.game.runs.find_by(...)`), so this can only fire on a caller that
  # skipped that scoping -- defense in depth, not the primary guard.
  def resolved_run
    return game.current_run if @run.nil?
    return nil unless @run.game_id == game.id

    @run
  end

  # finished? alone is also true for a passing ended by exit!, which is a
  # team that QUIT mid-course, not one that completed it -- GamePassing#exit!
  # stamps finished_at as well as status "exited". Without the exited? check,
  # a team could exit on level 1 and then fetch every level's file: this is
  # the same threat LogsController#ensure_full_log_access and GamePassing's
  # own `completed` scope guard against, for the same reason.
  #
  # This check does NOT cut an exited team off from the level it exited ON --
  # level_visible? still treats their (now frozen) current_level exactly as
  # it would for an actively playing team, so the delivery route keeps
  # serving files on that one level after exit!. That is by design, not a
  # gap this method is meant to close: GamePassingsController's
  # ensure_team_not_exited before_action is what stops an exited team from
  # reaching the PLAY SCREEN at all (see that controller), and it has no
  # equivalent here because there is nothing left to protect -- a file the
  # team could already see while playing tells them nothing new once they've
  # quit. Only levels BEYOND the exit point stay hidden, exactly as
  # completed?/level_visible? already guard.
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
  #
  # RESOLVED in Phase 3B (previously a known, documented limitation -- see
  # docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md
  # §4): a PAST run's log/results screen (LogsController#find_run,
  # GamePassingsController#find_run, both ?run=N) now passes that SAME run
  # to GameFileAccess.new(..., :run => @run), so `passing` above comes from
  # the run the screen is actually showing, not always game.current_run. A
  # team's finished run-1 passing authorises run-1's own attachments again
  # once run 2 has opened, without resolving "the team's passing in this
  # game" across every run -- which stays refused, deliberately: see
  # resolved_run's comment and the "team with a passing in more than one
  # run" specs, which pin that a LATER run's progress must never leak into
  # an EARLIER run's answer, or vice versa.
  def level_visible?(passing, level)
    return false unless level.game_id == game.id
    return true  if completed?(passing)

    current = passing.current_level
    return false if current.nil?
    return true  if level.id == current.id

    # Belt and braces, same spirit as passing_for_game's game_id re-check
    # above: acts_as_list keeps positions unique per game in normal use, so
    # two DIFFERENT levels sharing a position is corruption-only -- but this
    # comparison is the one actually deciding access, so it gets the
    # re-assertion the lesser game_id check already had. Guard against nil
    # first (Level#position nil raises NoMethodError, not just a wrong
    # answer, on the comparison below -- corruption-only, same as the
    # position collision) and use STRICT `<`, not `<=`: the only case that
    # legitimately needs "at or before" is the current level itself, already
    # handled above by id, so equal positions between two distinct level ids
    # (the corrupted case) fall through to a refusal instead of a permit.
    return false if level.position.nil? || current.position.nil?

    level.position < current.position
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

    hints_to_show_or_none(passing).include?(hint)
  end

  # hints_to_show calls Hint#ready_to_show? for EVERY hint on the current
  # level, not just the one this policy is deciding -- so a nil Hint#delay
  # anywhere on that level (`now - current_level_entered_at >= self.delay`,
  # comparing a Float with nil) raises ArgumentError before the enumeration
  # ever reaches the hint actually being checked here. Reachable only via a
  # corrupted row (update_column) -- delay has no validation forcing it
  # non-nil -- same shape as the position/game_id belt-and-braces elsewhere
  # in this file. This is pre-existing: the play screen already 500s on the
  # same nil today (out of scope to fix here -- see the review that flagged
  # this). What this route owns is its own contract, that everything not
  # permitted is a 404, never a distinguishable 500, so refuse rather than
  # let the raise reach the controller.
  def hints_to_show_or_none(passing)
    passing.hints_to_show
  rescue ArgumentError
    []
  end
end
