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
    # game_passings is preloaded because the view renders a count per row.
    # Without it this console issues one COUNT per game -- the one query
    # pattern a screen that lists *everything* can least afford.
    # :runs joins :author and :game_passings here for the same reason -- the
    # view renders a status and a start time per row, and both read the run.
    @games = Game.includes(:author, :game_passings, :runs).order(:created_at => :desc)
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
      redirect_to admin_games_path, :alert => t("admin.games.no_such_user") and return
    end

    # Read before the write: afterwards game.author is the successor, so the
    # entry would record the change as having no origin.
    previous = game.author&.nickname

    game.transfer_authorship_to!(successor)
    record_admin_action("set_author", game, "#{previous} -> #{successor.nickname}")

    redirect_to admin_games_path,
                :notice => t("admin.games.author_set", :nickname => successor.nickname)
  end

  # Opening another run of a finished game -- the console's second non-index
  # action. Every refusal returns BEFORE anything changes, matching set_author
  # and Admin::UsersController#revoke, so the log never holds an entry for a
  # change that did not happen.
  def open_run
    game = Game.find(params[:id])

    unless game.author_finished?
      redirect_to admin_games_path,
                  :alert => t("admin.games.cannot_open_unfinished") and return
    end

    if game.levels.empty?
      redirect_to admin_games_path,
                  :alert => t("admin.games.cannot_open_without_levels") and return
    end

    run = game.open_run!(:starts_at => params[:starts_at],
                         :registration_deadline => params[:registration_deadline],
                         :max_team_number => params[:max_team_number])

    record_admin_action("open_run", game, run.ordinal.to_s)
    redirect_to admin_games_path,
                :notice => t("admin.games.run_opened", :ordinal => run.ordinal)
  rescue ActiveRecord::RecordInvalid => e
    # The schedule is validated on the run in its :open context. Reporting its
    # own message rather than a generic one is what tells an operator WHICH
    # field is wrong.
    redirect_to admin_games_path, :alert => e.record.errors.full_messages.to_sentence
  end
end
