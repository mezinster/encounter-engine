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

  def ensure_game_was_not_started
    raise Authentication::Unauthorized, t("errors.game_already_started") if @game.started?
  end
end
