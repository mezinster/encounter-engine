# app/helpers/index_helper.rb
#
# The home page's per-game status: one tag (text and classes) for a game, as
# seen by the current visitor. Entry wording reuses the dashboard's keys
# (shared.game_entry_controls.*) so the two pages say the same thing.
module IndexHelper
  def home_registration_open?(game)
    game.status == :scheduled && game.can_request? &&
      (game.registration_deadline.nil? || game.registration_deadline > Time.now)
  end

  def home_status_tag(game, entry: nil, gated_live: false)
    return [t("index.index.running"), "tag tag--live"] if game.status == :running

    if game.pass_required?
      return gated_live ? [t("index.index.gated_live"), "tag tag--live"] : [t("index.index.gated"), "tag"]
    end

    case entry&.status
    when "new"      then [t("shared.game_entry_controls.applied"), "tag"]
    when "accepted" then [t("shared.game_entry_controls.registered"), "tag tag--live"]
    when "rejected" then [t("index.index.entry_rejected"), "tag tag--danger"]
    else
      if home_registration_open?(game)
        [t("index.index.registration_open"), "tag tag--live"]
      else
        [t("index.index.registration_closed"), "tag"]
      end
    end
  end

  # The signed-in user's team's entry for the game's current run -- the same
  # lookup the dashboard makes (GameEntry.of), memoised so each game costs one
  # query at most. Nil for guests, users with no team, and gated games (an
  # entry on a gated game authorises nothing).
  def home_entry_for(game)
    return nil unless logged_in? && current_user.team
    return nil if game.pass_required?

    @home_entries ||= {}
    @home_entries.fetch(game.id) { @home_entries[game.id] = GameEntry.of(current_user.team, game.current_run) }
  end
end
