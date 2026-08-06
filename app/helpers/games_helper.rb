# -*- encoding : utf-8 -*-
module GamesHelper
  # Team counts for a whole listing in two queries, regardless of how many
  # games it holds.
  #
  # This lives in a helper rather than in GamesController#index because
  # games/_list is rendered from TWO places -- games/index.html.erb and
  # dashboard/_my_games.html.erb -- and a controller-assigned variable would
  # be nil on the dashboard.
  #
  # Memoised per request on the exact set of ids, so a page rendering the
  # partial twice with different collections still gets one query pair each
  # and no stale reuse.
  def game_team_counts(games)
    ids = games.map(&:id).sort
    @game_team_counts ||= {}
    @game_team_counts[ids] ||= {
      # Deliberately NOT game.game_entries.with_status("accepted").count --
      # with_status is a scope, and a scope builds a new relation, so it
      # re-queries even when the association is already loaded. That exact
      # mistake shipped to review on the quiz branch.
      :registered => GameEntry.where(:game_id => ids, :status => "accepted").group(:game_id).count,
      :playing    => GamePassing.where(:game_id => ids).group(:game_id).count
    }
  end

  # The status tag. Withdrawn is the only danger state; running is the only
  # live one. Pausing is appended, never substituted -- a paused game is still
  # running, and Game#status deliberately does not encode pausing.
  def game_status_tag(game)
    modifier = case game.status
               when :withdrawn then " tag--danger"
               when :running   then " tag--live"
               else                 ""
               end

    tag = content_tag(:span, t("games.list.status_#{game.status}"), :class => "tag#{modifier}")
    tag += " ".html_safe + content_tag(:em, t("games.list.paused")) if game.paused?
    tag
  end

  # How long a finished game ran, or how long a running one has been going.
  # nil when there is nothing meaningful to say -- starts_at is nullable, and
  # "0 ч 0 мин" for a game that has not started would be a lie dressed as data.
  def game_duration_text(game)
    return nil if game.starts_at.nil?

    finish = case game.status
             when :finished then game.author_finished_at
             when :running  then game.paused_at || Time.now
             end
    return nil if finish.nil?

    hours, minutes = hours_and_minutes(finish - game.starts_at)
    t("games.list.duration", :hours => hours, :minutes => minutes)
  end
end
