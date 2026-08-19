# -*- encoding : utf-8 -*-
class GamesController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!, except: [:index, :show]
  before_action :find_game, only: [:show, :edit, :update, :delete, :end_game, :start_test, :finish_test, :new_withdrawal, :withdraw, :restore, :unfinish, :lock, :unlock, :hand_over, :set_content_locale]
  before_action :find_team, only: [:show]
  before_action :ensure_author_if_game_draft, only: [:show, :set_content_locale]
  before_action :ensure_author_if_no_start_time, only: [:show, :set_content_locale]
  before_action :ensure_author_if_game_is_withdrawn, only: [:show, :set_content_locale]
  before_action :ensure_author_if_game_is_testing, only: [:show, :set_content_locale]
  # hand_over is deliberately NOT on ensure_editing_not_locked below: that
  # filter answers with 401, and the lock refusal here is a sentence the author
  # can act on. See the action.
  before_action :ensure_author, only: [:edit, :update, :delete, :end_game, :start_test, :finish_test, :hand_over]
  before_action :ensure_editing_not_locked, only: [:edit, :update, :delete, :end_game, :start_test, :finish_test]
  before_action :ensure_game_was_not_started, only: [:edit, :update]
  before_action :require_superadmin!, only: [:new_withdrawal, :withdraw, :restore, :unfinish, :lock, :unlock]

  def index
    @games = if params[:user_id].present?
               games = User.find(params[:user_id]).created_games
               # A withdrawn game stays visible to its author and to an
               # operator; to everyone else this listing is as public as the
               # main one. Review finding: this branch used to be unscoped,
               # so GET /games?user_id=N rendered a withdrawn game to any
               # anonymous visitor.
               games = games.merge(Game.visible) unless logged_in? &&
                                                        (current_user.superadmin? || current_user.id == params[:user_id].to_i)
               games.includes(:runs)
             else
               Game.visible.includes(:runs)
             end
  end

  def new
    @game = Game.new
  end

  def create
    @game = Game.new(game_attributes.merge(author: current_user))

    if @game.save
      redirect_to @game
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    # includes(:team, :game) because games/_game_entries renders both per row.
    # It used to reach them through Team.find/Game.find, which no preload can
    # help; now that it goes through the associations, this is what keeps the
    # partial to one query instead of two per applicant.
    @game_entries = GameEntry.of_run(@game.current_run).with_status("new").includes(:team, :game)
    @teams = GameEntry.of_run(@game.current_run).with_status("accepted").map(&:team)
  end

  def edit
  end

  def update
    if @game.update(game_attributes)
      record_admin_action("update", @game) if acting_as_operator?(@game)
      redirect_to @game
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def delete
    unless @game.deletable?
      redirect_to @game, :alert => t("games.not_deletable") and return
    end

    operator = acting_as_operator?(@game)
    @game.destroy
    record_admin_action("delete", @game) if operator
    redirect_to dashboard_path
  end

  # A test run makes the game "started", so without this guard the end-game
  # link (games/_list) sat one click away from "finish testing" and set
  # author_finished_at permanently -- a timestamp finish_test's cleanup never
  # touched. The status damage stayed invisible while the game was a draft
  # (Game#status checks draft before finished) and surfaced only on
  # publication, as a scheduled game labelled "Завершена".
  def end_game
    if @game.is_testing?
      redirect_to @game, :alert => t("games.not_endable_in_test") and return
    end

    @game.finish_game!
    # THE GAME's passings, not the current run's: a commercial attempt has
    # game_run_id NULL and current_run.passings (scoped by game_run_id) can
    # never see it -- the same defect class Game#resume! and
    # InterventionsController#find_game_passing were already fixed for.
    # Without this, a runless attempt's status/finished_at stayed nil
    # forever: Team#in_live_race? stayed permanently true (the team could
    # never hand over captaincy or leave), the operator console kept showing
    # «проходится», and AccessPassesController#destroy refused to release the
    # pass because it still had an attempt.
    #
    # Every passing gets end! called, not just the unfinished ones, and not
    # just the CURRENT run's -- #game_passings names every run this game has
    # ever had, not only #current_run.passings. That is deliberately wider
    # than "every scheduled game today has a single run": Game#open_run! and
    # Admin::GamesController#open_run both create a second one, so a game
    # ended twice (once per run) sweeps an OLDER run's passings again here.
    # That repeat sweep is safe, not merely unlikely to matter: finish_game!
    # has exactly one caller (this action), so by the time a later run is
    # being ended, an earlier run's passings were already swept by the call
    # that ended IT -- every one of them is already "ended" or "exited".
    # end! skips exited? outright and, for an already-ended row, re-writes
    # the same status it already holds, so re-running it changes nothing.
    # A team that genuinely crossed the finish line also picks up status
    # "ended" here, which is what let the admin overview's "in progress"
    # count go to zero the moment the author closes the game (see
    # spec/requests/admin_passing_outcomes_spec.rb).
    @game.game_passings.each(&:end!)
    record_admin_action("end_game", @game) if acting_as_operator?(@game)
    redirect_to dashboard_path
  end

  # save, not save!. start_test sets visibility to "listed", which is exactly the
  # transition the translation-completeness gate guards, so a game with a
  # declared-but-untranslated language legitimately fails to save here.
  #
  # save! turned that into an unrescued ActiveRecord::RecordInvalid, Rails
  # answered 422, and because this app ships no public/422.html the browser got
  # a bare response that reads as "page does not exist" -- pointing the author
  # at routes.rb for a problem that is actually "you have not finished
  # translating". The reason was computed, attached as errors[:base], and then
  # discarded by the exception. Surface it instead.
  def start_test
    @game.visibility = "listed"
    @game.is_testing = true
    @game.test_date = @game.starts_at
    @game.starts_at = Time.now + 0.1.second
    # The deadline is deliberately LEFT ALONE. It used to be blanked here,
    # because moving starts_at to now makes any future deadline violate
    # deadline_is_before_game_start -- but unlike starts_at, which is stashed
    # in test_date and restored by finish_test, it was simply destroyed, and
    # an author who rehearsed their game silently lost the cutoff they had
    # set. Game skips both deadline validations while is_testing? instead.

    unless @game.save
      redirect_to @game, :alert => @game.errors.full_messages.to_sentence and return
    end

    # After the save, not before: the save can legitimately fail on the
    # translation-completeness gate above, and a token minted for a test that
    # never started would be a live credential to an unpublished game.
    #
    # update_column for the same reason every other lifecycle writer on this
    # model uses it -- a game mid-test does not pass its own validations, so
    # update! would raise and update would fail silently.
    @game.current_run.update_column(:test_token, SecureRandom.urlsafe_base64(24))

    record_admin_action("start_test", @game) if acting_as_operator?(@game)
    redirect_to @game
  end

  def new_withdrawal
  end

  def withdraw
    @game.withdraw!(:category => params[:withdrawal_category],
                    :mode     => params[:withdrawal_mode],
                    :note     => params[:withdrawal_note].presence)

    # The note is appended only when there is one: "technical/freeze: " with a
    # dangling colon reads like a truncated entry to whoever is reading the log
    # during an incident. The full note is on the game either way -- this line
    # exists so the audit is legible on its own.
    detail = "#{params[:withdrawal_category]}/#{params[:withdrawal_mode]}"
    detail << ": #{params[:withdrawal_note]}" if params[:withdrawal_note].present?

    record_admin_action("withdraw", @game, detail)
    redirect_to admin_games_path, :notice => t("games.withdrawn_notice")
  rescue ArgumentError
    # A missing or unknown category OR mode is a form error the operator can
    # correct on the spot, not a refusal to report elsewhere -- withdraw!
    # raises ArgumentError for both.
    render :new_withdrawal, :status => :unprocessable_entity
  end

  def restore
    @game.restore!
    record_admin_action("restore", @game)
    redirect_to admin_games_path, :notice => t("games.restored_notice")
  end

  # Revival of an ended game -- the reverse of end_game, restricted to
  # superadmins as incident repair rather than an author flow. Team passings
  # marked "ended" are deliberately left alone: the reinstate intervention
  # already revives teams one by one with a fair clock reset. See
  # docs/superpowers/specs/2026-08-08-superadmin-unfinish-design.md.
  def unfinish
    @game.unfinish!
    record_admin_action("unfinish", @game)
    redirect_to admin_games_path, :notice => t("games.unfinished_notice")
  end

  def lock
    @game.lock_editing!
    record_admin_action("lock", @game)
    redirect_to admin_games_path, :notice => t("games.locked_notice")
  end

  def unlock
    @game.unlock_editing!
    record_admin_action("unlock", @game)
    redirect_to admin_games_path, :notice => t("games.unlocked_notice")
  end

  # Handing the game to another player. Mirrors TeamsController#hand_over,
  # including its asymmetry.
  def hand_over
    # These two refusals are the AUTHOR's, not the operator's. A superadmin has
    # no lifecycle refusals at all -- exactly as ensure_editing_not_locked
    # already exempts them everywhere else -- which is why this is an in-action
    # check and not that filter: the filter answers with 401, and an author
    # meeting a rule deserves a sentence explaining it.
    unless current_user.superadmin?
      if @game.editing_locked?
        redirect_to games_path, :alert => t("games.hand_over.locked") and return
      end

      if @game.started? && !@game.author_finished?
        redirect_to games_path, :alert => t("games.hand_over.running") and return
      end
    end

    successor = User.find_by(:nickname => params[:nickname].to_s.strip)

    # Unlike Team#set_captain! there is no members association to scope the
    # lookup through -- the target is any user on the instance -- so exactness
    # IS the guard. Not-found and self-transfer share one message so the field
    # cannot be used to discover which nicknames exist.
    if successor.nil? || successor.id == current_user.id
      redirect_to games_path, :alert => t("games.hand_over.unknown_user") and return
    end

    # Both read BEFORE the write: afterwards @game.author is the successor, so
    # neither the audit details nor the operator test would say what happened.
    operator = acting_as_operator?(@game)
    previous = @game.author&.nickname

    @game.transfer_authorship_to!(successor)

    record_admin_action("hand_over_authorship", @game,
                        "#{previous} -> #{successor.nickname}") if operator

    # The games LIST, not the game. A draft sits behind
    # ensure_author_if_game_draft, so redirecting to a game the caller has
    # just stopped authoring would answer a successful transfer with 401.
    redirect_to games_path, :notice => t("games.hand_over.done", :nickname => successor.nickname)
  end

  # Which language this reader wants THIS game's authored content in.
  #
  # The play screen has the same switcher, but its route is behind the
  # play-time filters -- started game, on a team in it. An author who picked
  # another language while testing a translation was then stuck with it on
  # this page, with nothing here to change it back and no way to reach the
  # play screen once the game was stopped.
  #
  # Guarded by exactly the filters #show is guarded by: if you can read the
  # game, you can record which language you read it in.
  def set_content_locale
    store_content_locale(@game, params[:locale])
    redirect_to game_path(@game)
  end

  # Same treatment as start_test. This direction sets visibility back to
  # "draft" so the gate cannot fire, but another validation still can -- and
  # an author stuck in test mode with a blank 422 has no way to understand why.
  def finish_test
    @game.visibility = "draft"
    @game.is_testing = false
    @game.starts_at = @game.test_date
    @game.test_date = Time.now
    # An author finish acquired during the test is as much a trace of the run
    # as the passings and logs deleted below -- left in place it outlives the
    # test and marks the real game "Завершена" once it leaves draft.
    @game.author_finished_at = nil

    unless @game.save
      redirect_to @game, :alert => @game.errors.full_messages.to_sentence and return
    end

    # Scoped to the run, and this one matters more than its size suggests: it
    # deletes player history, and in phase 3 a test run must not erase a real
    # run's results.
    #
    # A RELATION, not the has_many proxy. GameRun#passings carries no
    # dependent: option, and delete_all on such a proxy NULLIFIES the foreign
    # key instead of deleting rows -- so `current_run.passings.delete_all`
    # would leave every passing in place with game_run_id set to NULL, which
    # looks identical to a successful wipe from any run-scoped count.
    #
    # The ledger rows go with them, and BEFORE them -- they are reached
    # through the passings, so deleting the passings first would leave nothing
    # to identify them by. An append-only ledger may still lose rows here:
    # append-only means the ledger is never REVERSED (no compensating entry,
    # no edit -- see PointTransaction's class comment), not that a row
    # outlives the run it describes. This run is being erased, so what it
    # earned is erased with it, exactly as its logs are.
    #
    # Not merely tidiness. start_test flips an ALREADY RUNNING real game into
    # testing mode, so a real run's rows can arrive here; left behind they
    # were orphaned (Game#deletable? and Team#deletable? both refuse while any
    # exist, and the passings that explain them are gone, so no UI could ever
    # clear them) and the public team page showed an empty games table above a
    # ledger with a balance. See the whole-branch review, F3.
    passings = GamePassing.where(:game_run_id => @game.current_run.id)
    PointTransaction.where(:game_passing_id => passings.select(:id)).delete_all
    passings.delete_all
    Log.of_run(@game.current_run).delete_all

    # After the two deletions above, deliberately: the deletable? predicate
    # refuses a team that still holds a passing or a log line, so sweeping
    # first would spare every disposable team this test created.
    #
    # The deletion on the line above is keyed on game_passing_id, which is
    # complete for every row gameplay writes and blind to a GLOBAL adjustment
    # (PointTransaction.adjust! with `passing: nil`, which belongs to the team
    # and to no run). Nothing extra is needed HERE: a global row is not this
    # run's to erase, and the one case where it must go -- a disposable team
    # being destroyed -- is handled inside the sweep below, through
    # Team#destroy_with_ledger!. F1 of the operator-adjustments whole-branch
    # review.
    @game.current_run.sweep_test_admissions!

    record_admin_action("finish_test", @game) if acting_as_operator?(@game)
    redirect_to @game
  end

  private

  # Merb passed params[:game] straight to update_attributes with no
  # top-level key required. fetch (rather than require) keeps that
  # tolerance -- a request with no :game key at all builds a blank/invalid
  # Game instead of raising ActionController::ParameterMissing -- while
  # permit still closes the mass-assignment hole. Field list matches the
  # actual form fields in app/views/games/new.html.erb and edit.html.erb;
  # is_testing is never submitted by either form (it's flipped only via
  # #start_test/#finish_test) so it is intentionally not permitted here.
  def game_params
    params.fetch(:game, ActionController::Parameters.new)
          .permit(:name, :description, :starts_at, :registration_deadline,
                   :max_team_number, :visibility, :primary_locale, :access_mode,
                   :points_enabled, :level_completion_points, :game_completion_points,
                   :max_skips, :skip_points_fine, :skip_time_penalty,
                   :available_locale_list => [],
                   :translations => translation_params_shape(Game::TRANSLATABLE_FIELDS))
  end

  # params.permit cannot express "any locale key", so build the shape from the
  # locales this platform actually knows.
  def translation_params_shape(fields)
    I18n.available_locales.map(&:to_s).index_with { fields.map(&:to_sym) }
  end

  # translations_attributes= is the concern's writer; the form posts
  # `translations` because that is what reads naturally in the markup.
  #
  # access_mode is stripped here, not merely hidden from the form: permitting
  # the param already closes the mass-assignment hole Rails cares about, but
  # an ordinary author could still hand-craft a POST with
  # game[access_mode]=pass_required and have it accepted, because
  # game_attributes has no notion of WHO is asking. Deleting the key unless
  # the actor holds may_operate_commercial? is what actually enforces "this
  # is operator territory" -- see the games/new and games/edit views, which
  # render the control under the identical predicate so an ordinary author
  # never sees a field their POST would be refused anyway.
  def game_attributes
    attributes = game_params.to_h
    translations = attributes.delete("translations")
    attributes.delete("access_mode") unless logged_in? && current_user.may_operate_commercial?
    attributes.merge("translations_attributes" => translations)
  end

  # :show and :edit render @game.translated(...) (see Finding 2 of the
  # whole-branch review -- players and authors both now read translated
  # name/description instead of the raw column), which touches
  # content_translations; preload it so that costs one query per page
  # instead of a lazy load the first time translated() is called.
  def find_game
    @game = Game.includes(:content_translations).find(params[:id])
  end

  # No view reads @team today (Task 9 hasn't ported app/views/games/show yet),
  # but the Merb original set it unconditionally on #show and dropping it
  # silently would change what that port can rely on.
  def find_team
    @team = current_user&.team
  end

  def game_draft?
    @game.draft?
  end

  def no_start_time?
    @game.starts_at.nil?
  end

  # A draft or not-yet-scheduled game is only visible to its author -- a
  # guest or any other user gets Unauthorized (via SecurityFilters#ensure_author,
  # which itself distinguishes "not logged in" from "logged in but not the
  # author" -- both land here as a 401, matching the Merb original). Without
  # these two guards, an unpublished game's name/description/level count
  # leak from the moment its author saves the draft, before it's meant to be
  # public.
  def ensure_author_if_game_draft
    ensure_author if game_draft?
  end

  # A gated game legitimately has no start time -- it never gets one, and
  # never will -- so "no start time" cannot mean "not yet scheduled, author
  # only" for it the way it does for a scheduled game. Without this
  # exemption, every gated game's own show page 401'd its paying customers,
  # who hold a pass but are neither the author nor a superadmin.
  def ensure_author_if_no_start_time
    return if @game.pass_required?

    ensure_author if no_start_time?
  end

  # A withdrawn game vanishes from every listing, but the listing is not the
  # only way in -- a URL survives in chat logs, bookmarks and invitations. Its
  # author and a superadmin must still reach it; nobody else should.
  def ensure_author_if_game_is_withdrawn
    return unless @game.withdrawn?
    return if logged_in? && (current_user.superadmin? || current_user.author_of?(@game))

    raise Authentication::Unauthorized, t("errors.game_is_withdrawn")
  end

  # The fourth sibling, and it exists because the first one stops working.
  # ensure_author_if_game_draft keeps non-authors off an unpublished game --
  # but start_test sets visibility to "listed", so from the moment a rehearsal
  # begins that guard lapses and the page becomes world-readable. Reported
  # from production 2026-08-15, together with the listing leak Game.visible
  # now closes.
  #
  # Wider than its siblings by one case: an admitted TESTER must reach the game
  # they were invited to. That is the only widening -- a stranger with the URL
  # is refused exactly as a stranger visiting a withdrawn game is.
  def ensure_author_if_game_is_testing
    return unless @game.is_testing?
    return if logged_in? && (current_user.superadmin? || current_user.author_of?(@game))
    return if logged_in? && admitted_to_test?

    raise Authentication::Unauthorized, t("errors.game_is_not_testing")
  end

  # This filter had the both-shapes rule right while the dashboard block had it
  # wrong, and they disagreed from the day test-run invitations landed: an
  # admitted team was let onto the game page and shown no way to reach it.
  # Sharing one definition is the actual fix -- restating the rule in each
  # reader is what let them drift apart.
  def admitted_to_test?
    TestAdmission.held_by(current_user).of_run(@game.current_run).exists?
  end
end
