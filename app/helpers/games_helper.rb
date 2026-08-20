# -*- encoding : utf-8 -*-
module GamesHelper
  # Whether the SIGNED-IN user's team may currently play each gated game in
  # `games`, keyed by game id -- one query for the whole listing, regardless
  # of how many gated rows it holds. "May currently play" is AccessPass#live?
  # across every pass the team holds for that game: not revoked, and not
  # spent (spent? already covers both "finished" and "quit", and a live pass
  # covers both "not started yet" and "attempt in progress", since an
  # in-progress attempt has no finished_at -- see AccessPass#live?/#spent?).
  #
  # Deliberately NOT GamePassing.gated_attempt_for: that method answers "which
  # ROW is this team's canonical attempt", a question this per-row yes/no
  # check never asks, and calling it once per gated row would be exactly the
  # per-row query this method exists to avoid (spec/requests/
  # games_listing_spec.rb pins the flat count, the same shape fd96d51 fixed
  # for the admin console's access_passes preload).
  #
  # No team, or no gated rows in this listing: {} (falsy for every game id,
  # so a caller need not special-case either).
  def gated_play_status(games)
    return {} unless logged_in? && current_user.team

    gated_ids = games.select(&:pass_required?).map(&:id)
    return {} if gated_ids.empty?

    team = current_user.team
    @gated_play_status ||= {}
    @gated_play_status[[team.id, gated_ids.sort]] ||=
      AccessPass.where(:game_id => gated_ids, :team_id => team.id, :revoked_at => nil)
                .includes(:attempt)
                .group_by(&:game_id)
                .transform_values { |passes| passes.any?(&:live?) }
  end

  # The three figures a COMMERCIAL row shows, keyed by game id: how many teams
  # currently hold access, how many are mid-attempt, how many finished.
  # Two queries for the whole listing, and none at all when it holds no gated
  # row -- the same self-guarding shape as #gated_play_status above, which is
  # what keeps the flat-count examples in spec/requests/games_listing_spec.rb
  # true for a scheduled-only listing.
  #
  # A gated row cannot reuse #game_team_counts below. Every figure there is
  # scoped to the current RUN, and a commercial attempt has game_run_id NULL by
  # design (the paid-game design, task 6), so those counts are structurally
  # blind to it -- which is how a converted game came to show its stale
  # free-era registration count while selling passes nobody could see.
  #
  # DERIVED, never stored, and that is the requirement rather than an
  # implementation detail: an operator can set access_mode back to "scheduled"
  # and the free counters must return to exactly what they were. They do,
  # because a conversion touches no row this reads -- entries,
  # requested_teams_number and run-scoped passings all survive it untouched.
  # A denormalised counter is precisely the thing that would then need
  # un-winding.
  def gated_participation_counts(games)
    gated_ids = games.select(&:pass_required?).map(&:id)
    return {} if gated_ids.empty?

    @gated_participation_counts ||= {}
    @gated_participation_counts[gated_ids.sort] ||= begin
      # game_run_id NULL IS the gated selector -- see above. Scoping on
      # access_mode instead would also sweep in the run-scoped passings a
      # converted game carries from its free era.
      attempts = GamePassing.where(:game_id => gated_ids, :game_run_id => nil)

      {
        # Not revoked: this answers "how many teams currently hold access",
        # not "how many were ever handed one". A revoked pass is an
        # entitlement the operator took back, and AccessPass#live? treats it
        # as gone everywhere else.
        :issued    => AccessPass.where(:game_id => gated_ids, :revoked_at => nil)
                                .group(:game_id).count,
        # The scopes, not a hand-written predicate. Both carry the nullable-
        # status care that a plain `NOT IN` gets wrong -- see :playing in
        # #game_team_counts below, which is the same trap and which this
        # change stopped restating inline.
        :playing   => attempts.in_progress.group(:game_id).count,
        # COMPLETED, not merely finished: finished_at set and not exited, the
        # same pair Game#pass_standings sorts and the same pair
        # AccessPass#spent? reduces to. Anything else would let this listing
        # disagree with the standings, or with whether a pass was consumed.
        :completed => attempts.completed.group(:game_id).count
      }
    end
  end

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
    @game_team_counts[ids] ||= begin
      # Every count here is scoped to the CURRENT run, which is what the rest
      # of the application means by a game's teams: GamesController#show
      # (GameEntry.of_run), GamePassingsController#index
      # (current_run.passings), DashboardController and the admin entries
      # console all read one run. This helper grouped by game_id alone and was
      # the only place that did not -- so on a game that has been run twice it
      # summed both runs' registrations and passings, and divided them by a
      # max_team_number that Game delegates to the current run only
      # (app/models/game.rb). The numerator and the denominator answered
      # different questions.
      #
      # Filtering by run id and still grouping by game_id is safe and is what
      # keeps this to two queries: a run id belongs to exactly one game, and
      # exactly one run per game is in this list.
      #
      # game.current_run is free where the caller preloaded runs
      # (GamesController#index does `.includes(:runs)`, and #current_run is
      # `runs.to_a.last`); the dashboard already pays the same per-game read in
      # #accepted_teams_by_game. compact because #current_run AUTOBUILDS an
      # unsaved run for a game that somehow has none, and an unsaved record
      # has no id.
      run_ids = games.map { |game| game.current_run.id }.compact

      {
        # Deliberately NOT game.game_entries.with_status("accepted").count --
        # with_status is a scope, and a scope builds a new relation, so it
        # re-queries even when the association is already loaded. That exact
        # mistake shipped to review on the quiz branch.
        :registered => GameEntry.where(:game_run_id => run_ids, :status => "accepted").group(:game_id).count,
        # "playing" (games.list.playing, shown on a running game) means
        # *currently* playing, which is exactly GamePassing.in_progress: no
        # finished_at (excluding teams that finished normally or exited, since
        # exit! always stamps it) and status not "ended" (an operator-ended
        # team keeps finished_at nil, so the timestamp alone would miss them).
        #
        # This was an inline relation restating that scope character for
        # character, including the `.where(:status => nil).or(...)` form --
        # which is not stylistic: status is nullable and nil is the ordinary
        # in-progress value, so a plain `.where.not(:status => %w[exited
        # ended])` generates `status NOT IN (...)`, NULL under SQL's
        # three-valued logic, and would silently zero out the common case.
        # Now stated once, in the model, and read here.
        :playing    => GamePassing.where(:game_run_id => run_ids).in_progress.group(:game_id).count,
        # "played" (games.list.played, shown on a finished game) means *took
        # part at all* -- every passing created for this run, regardless of how
        # it ended.
        :played     => GamePassing.where(:game_run_id => run_ids).group(:game_id).count
      }
    end
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
    # Pausing only means something on a game that is actually running --
    # finish_game! never clears paused_at, so a game paused and then ended
    # without being resumed would otherwise still read game.paused? true and
    # render "Завершена · на паузе", a status that contradicts itself.
    tag += " ".html_safe + content_tag(:em, t("games.list.paused")) if game.status == :running && game.paused?
    tag
  end

  # What to say about who's playing/played a game, or nil to say nothing.
  #
  # A running game normally reports who is *currently* playing. But once
  # every team that joined has finished (and the author has not yet ended
  # the game), that count is zero -- rendering byte-identical to a scheduled
  # game nobody has joined at all, and hiding real information ("2 teams
  # played, both are done") for as long as the author takes to notice and
  # press "end game". So a running game with nobody currently playing falls
  # back to who took part. A finished game always shows who took part. A
  # scheduled game with nobody registered still says nothing -- there is
  # nothing to fall back to.
  def game_participation_text(game, counts)
    playing = counts[:playing].fetch(game.id, 0)
    played  = counts[:played].fetch(game.id, 0)

    count, key = case game.status
                 when :finished
                   [played, :played]
                 when :running
                   playing > 0 ? [playing, :playing] : [played, :played]
                 else
                   [playing, :playing]
                 end

    t("games.list.#{key}", :count => count) if count > 0
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
    # end_game has no started? guard (config/routes.rb, GamesController#end_game),
    # so an author can end a game whose start is still in the future, making
    # finish < starts_at. Ruby's floor division then turns the negative
    # interval into a doubly-wrong value (-7260s renders "-3 ч 59 мин", not
    # the true "-2 ч 1 мин") -- rather than render that, say nothing, same as
    # any other case with nothing meaningful to report.
    return nil if finish < game.starts_at

    hours, minutes = hours_and_minutes(finish - game.starts_at)
    t("games.list.duration", :hours => hours, :minutes => minutes)
  end
end
