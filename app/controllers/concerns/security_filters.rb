# -*- encoding : utf-8 -*-
# Ported from app/controllers/secutity_filters.rb (Merb), spelling corrected.
# These four guards were mixed into every controller that inherited from the
# old Application base class; here they are `include`d only where the
# corresponding controller actually uses them.
module SecurityFilters
  extend ActiveSupport::Concern

  private

  def ensure_team_member
    raise Authentication::Unauthorized, t("errors.not_team_member") unless current_user.member_of_any_team?
  end

  def ensure_team_captain
    raise Authentication::Unauthorized, t("errors.must_be_captain") unless current_user.captain?
  end

  # Deliberately checks logged_in? itself rather than relying on a separate
  # require_authentication! filter: LevelsController has no authentication
  # filter of its own (see levels.rb in the Merb app), so this single guard
  # has to reject both guests and logged-in non-authors with the same
  # Unauthorized response. GamesController, which does run
  # require_authentication! first, never reaches the `unless logged_in?`
  # branch -- current_user is already guaranteed there.
  # SECURITY CHOKEPOINT. Widening this admits superadmins to every action that
  # gates on it -- levels, hints, questions, game entries -- which is the point:
  # an operator who can edit a game can already edit its levels, and a parallel
  # permission system would drift out of sync with this one. The consequence is
  # that any FUTURE call site of ensure_author silently admits superadmins too.
  def ensure_author
    return if logged_in? && current_user.superadmin?

    raise Authentication::Unauthorized, t("errors.must_be_author") unless logged_in? && current_user.author_of?(@game)
  end

  def require_superadmin!
    raise Authentication::Unauthorized, t("errors.must_be_superadmin") unless logged_in? && current_user.superadmin?
  end

  # Deliberately NOT part of ensure_author. That filter is shared by read-only
  # views too -- the live log, the level and game logs, the team-passings list --
  # and an author under investigation should still be able to watch their own
  # game. The lock covers content, settings AND lifecycle (GamesController
  # applies this to edit/update/delete as well as end_game/start_test/
  # finish_test) -- finish_test in particular deletes every game_passing and
  # log line, which would let a locked author erase the evidence an operator
  # locked the game to investigate, and then delete the game itself now that
  # it has no game_passings left. Read-only views stay off this filter.
  def ensure_editing_not_locked
    return if logged_in? && current_user.superadmin?

    raise Authentication::Unauthorized, t("errors.game_is_locked") if @game&.editing_locked?
  end

  def ensure_game_was_not_started
    raise Authentication::Unauthorized, t("errors.game_already_started") if @game.started?
  end

  # Interventions only make sense on a game that is actually being played.
  #
  # Two exemptions are load-bearing. A PAUSED game is live: treating it
  # otherwise would put #resume behind a condition only #resume can clear, an
  # action no request could ever reach. A game in TEST mode is live: is_testing
  # games skip ensure_game_is_started throughout GamePassingsController, and an
  # author testing their own game is exactly who wants to move a team between
  # levels.
  def ensure_game_is_live
    return if @game.is_testing?

    live = @game.started? && !@game.draft? && !@game.withdrawn? && !@game.author_finished?
    raise Authentication::Unauthorized, t("errors.game_is_not_live") unless live
  end
end
