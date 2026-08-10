# -*- encoding : utf-8 -*-
class LogsController < ApplicationController
  include SecurityFilters
  include Pagination

  before_action :require_authentication!
  before_action :find_game
  before_action :find_run
  before_action :ensure_author, only: [:show_live_channel, :show_level_log, :show_game_log]
  before_action :ensure_full_log_access, only: [:show_full_log]
  before_action :find_team, only: [:show_level_log, :show_game_log]
  before_action :find_level, only: [:show_level_log, :show_game_log]

  # #index has no route in config/routes.rb (Task 7 only wired the four
  # show_* paths) -- same as the Merb original, whose router.rb also never
  # mapped a path to Logs#index. Kept for behavioural parity even though
  # it's unreachable both before and after this port.
  def index
  end

  # SECURITY FIX (see .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-S-report.md):
  # show_full_log used to be reachable by ANY logged-in user -- it was
  # deliberately left out of the :ensure_author list above, matching the
  # Merb original (app/controllers/logs.rb), which had no author check on
  # this action at all. Since the view prints every level's correct_answer
  # for the whole game, that let a team still playing a live game read every
  # remaining answer code. The full log has two legitimate audiences --
  # the game's author (features/logs/log.feature:105) and a player whose
  # team has *finished* the game (features/logs/log.feature:113) -- so
  # #show_full_log now goes through :ensure_full_log_access instead of
  # :ensure_author, which allows exactly those two cases and blocks a team
  # that is still mid-game.
  # order(:time => :desc) is the order this ALREADY produced: the view's
  # comparator returned 1 when left.time <= right.time, i.e. newest first.
  # Doing it in SQL is what lets the page stop loading every log for the run.
  def show_live_channel
    scope = Log.of_run(@run).includes(:team_record, :level_record).order(:time => :desc)
    @logs, @page, @total_pages = page_of(scope, params[:page], :per => 50)
  end

  def show_level_log
    # find_level (before_action) resolves @level via Team#current_level_in,
    # which returns nil once GamePassing#pass_level! finishes a team's game
    # (current_level is niled on the final level -- see GamePassing#pass_level!).
    # Reachable only by a finished team hitting this URL directly; no UI link
    # does it. Guard explicitly rather than calling of_level(nil): the id-scoped
    # fallback above still resolves `level.id`/`level.name` on its argument, so
    # a nil @level would raise the same NoMethodError the old name-only scope
    # did -- but relying on that as the safety net is an accident waiting to
    # break the next time this scope changes shape. Render the normal page
    # with an empty log (the view guards @level itself) rather than a blank
    # response.
    @logs = @level ? Log.of_run(@run).of_team(@team).of_level(@level) : Log.none
  end

  def show_game_log
    @logs = Log.of_run(@run).of_team(@team)
  end

  def show_full_log
    # Level.of_game, deliberately: levels are the game's CONTENT and are shared
    # by every run of it. Only the answers belong to one running.
    #
    # questions => answers preloaded because the view prints every level's
    # correct answer. Without it each level costs four more queries -- a COUNT,
    # the questions themselves, and the two Question#correct_answer makes
    # (answers.empty? then answers.first). That is the same per-row shape as
    # the cell N+1 below, on the same page, and the query-count guard measures
    # both together.
    #
    # Paged by LEVEL -- the rows this matrix lists -- in the order acts_as_list
    # keeps them, so page 1 is levels 1-20 rather than an arbitrary twenty.
    @levels, @page, @total_pages =
      page_of(Level.of_game(@game).includes(:questions => :answers).order(:position),
              params[:page], :per => 20)

    # Loaded, not a relation, and only this page's levels. The view groups
    # these in Ruby; leaving it lazy is what produced one query per level x
    # team cell.
    @logs = Log.of_run(@run).where(:level_id => @levels.map(&:id)).to_a
    # Not find_by_sql("select * from teams t inner join game_passings gp ...")
    # -- a bare `select *` across that join returns `id` twice (teams.id, then
    # game_passings.id) and the later column wins, so every row would carry
    # the game_passing's id, not the team's. `name` survived because
    # game_passings has no name column, which is exactly why the old
    # name-based of_team scope worked against these rows and the id-based one
    # does not: of_team(team) filters on the wrong id and finds nothing.
    #
    # game_run_id, not game_id: scoped to the game this listed a column for
    # every team that ever played it, whichever run was being shown.
    @teams = Team.joins(:game_passings)
                 .where(:game_passings => { :game_run_id => @run.id }).distinct
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  # The ORDINAL, not the id: stable, human-readable, and meaningful in a URL
  # someone might share. Unknown or malformed falls back to the current run
  # rather than 404ing.
  #
  # Simply current_run as the default, unlike the results page: no started-run
  # guard applies to these screens, so there is no run this can choose that the
  # filters would then refuse.
  def find_run
    @run = @game.runs.find_by(:ordinal => params[:run].to_i) || @game.current_run
  end

  def find_team
    @team = Team.find(params[:team_id])
  end

  def find_level
    @level = @team.current_level_in(@game)
  end

  # Allowed: the game's author, or a player on a team that genuinely
  # finished the game -- GamePassing#finished? alone is not enough, because
  # it is also true for a team that merely *exited* (GamePassing#exit! sets
  # finished_at too). An exited team cannot resume play (ensure_team_not_exited
  # in GamePassingsController blocks both GET and POST /play/:id), but
  # without the exited? check here, one team could exit on purpose mid-game
  # purely to unlock the full log and relay every remaining answer code to
  # a colluding team that is still playing -- the cost of that attack is one
  # throwaway team, not actually finishing the game. Both real full-log
  # scenarios (features/logs/log.feature:113,
  # features/games/game_full_log.feature:20) reach this page by completing
  # every level through real gameplay, never by exiting, so requiring
  # !exited? breaks neither. Blocked: a team still mid-game, an exited team,
  # and anyone with no team at all.
  def ensure_full_log_access
    return if @game.created_by?(current_user)

    game_passing = current_user.team && @game.current_run.passing_for(current_user.team)
    unless game_passing&.finished? && !game_passing.exited?
      raise Authentication::Unauthorized, t("errors.must_be_author_or_finished_player")
    end
  end
end
