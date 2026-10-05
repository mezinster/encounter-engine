# Read-only by design, with one exception. Editing rides the author's own forms
# -- ensure_author admits superadmins -- so there is no second, subtly
# different game editor to keep in sync with the first.
#
# set_author is the exception because there is no author's form to borrow when
# the whole point is that the current author cannot or will not act. It writes
# through Game#transfer_authorship_to!, the same method the author's own path
# calls; nothing here touches author_id directly.
class Admin::GamesController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # "What just appeared on my instance?" is the operator's first question.
    #
    # Only what each row reads: the author's nickname, and the run (status and
    # the pending-entry lookup below both go through current_run). Team counts
    # come from game_team_counts -- two grouped queries for the whole page.
    #
    # The list used to call Game#deletable? per row, so passings, access
    # passes, access codes and the points ledger were preloaded alongside.
    # Those controls moved to the per-game page (admin/games/show) on
    # 2026-10-05, and the preloads went with them: kept here, they pulled the
    # instance's largest tables into memory on every visit for nothing
    # (admin_console_spec.rb, "does not load tables the list no longer reads").
    # A control that calls deletable? per row again needs them back.
    @games = Game.includes(:author, :runs)
                 .order(:created_at => :desc)

    # ONE grouped query for the whole page, not one per row. :runs is already
    # preloaded above, so current_run costs nothing here -- and the comment on
    # the includes above records why a per-row count is the one pattern this
    # screen can least afford.
    @pending_entry_counts = GameEntry.with_status("new")
                                     .where(:game_run_id => @games.map { |g| g.current_run.id })
                                     .group(:game_run_id)
                                     .count
  end

  # Every per-game control the list used to carry in each row, grouped into
  # panels. One game, so the list's batching concerns do not arise: the counts
  # below are single queries.
  def show
    @game = Game.includes(:author, :runs).find(params[:id])
    @pending_entry_count = GameEntry.with_status("new")
                                    .where(:game_run_id => @game.current_run.id)
                                    .count
  end

  # No lifecycle refusals, deliberately -- the same exemption the comment on
  # Team#in_live_race? documents for the superadmin captaincy path. An operator
  # reassigns a game precisely BECAUSE it is running badly.
  def set_author
    game = Game.find(params[:id])
    successor = User.find_by(:nickname => params[:nickname].to_s.strip)

    # Refused before anything changes, matching Admin::UsersController#revoke,
    # so the log never holds an entry for a change that did not happen.
    if successor.nil?
      redirect_to admin_game_path(game), :alert => t("admin.games.no_such_user") and return
    end

    # Read before the write: afterwards game.author is the successor, so the
    # entry would record the change as having no origin.
    previous = game.author&.nickname

    game.transfer_authorship_to!(successor)
    record_admin_action("set_author", game, "#{previous} -> #{successor.nickname}")

    redirect_to admin_game_path(game),
                :notice => t("admin.games.author_set", :nickname => successor.nickname)
  end

  # Opening another run of a finished game -- the console's second non-index
  # action. Every refusal returns BEFORE anything changes, matching set_author
  # and Admin::UsersController#revoke, so the log never holds an entry for a
  # change that did not happen.
  def open_run
    game = Game.find(params[:id])

    unless game.author_finished?
      redirect_to admin_game_path(game),
                  :alert => t("admin.games.cannot_open_unfinished") and return
    end

    if game.levels.empty?
      redirect_to admin_game_path(game),
                  :alert => t("admin.games.cannot_open_without_levels") and return
    end

    run = game.open_run!(:starts_at => params[:starts_at],
                         :registration_deadline => params[:registration_deadline],
                         :max_team_number => params[:max_team_number])

    record_admin_action("open_run", game, run.ordinal.to_s)
    redirect_to admin_game_path(game),
                :notice => t("admin.games.run_opened", :ordinal => run.ordinal)
  rescue ActiveRecord::RecordInvalid => e
    # The schedule is validated on the run in its :open context. Reporting its
    # own message rather than a generic one is what tells an operator WHICH
    # field is wrong. The run's messages are whole sentences, so they are joined
    # as sentences (SentenceJoin), not glued with to_sentence's "и".
    redirect_to admin_game_path(game), :alert => SentenceJoin.call(e.record.errors.full_messages)
  end
end
