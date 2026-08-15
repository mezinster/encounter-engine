# -*- encoding : utf-8 -*-
class GamesController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!, except: [:index, :show]
  before_action :find_game, only: [:show, :edit, :update, :delete, :end_game, :start_test, :finish_test, :withdraw, :restore, :unfinish, :lock, :unlock, :hand_over]
  before_action :find_team, only: [:show]
  before_action :ensure_author_if_game_is_draft, only: [:show]
  before_action :ensure_author_if_no_start_time, only: [:show]
  before_action :ensure_author_if_game_is_withdrawn, only: [:show]
  # hand_over is deliberately NOT on ensure_editing_not_locked below: that
  # filter answers with 401, and the lock refusal here is a sentence the author
  # can act on. See the action.
  before_action :ensure_author, only: [:edit, :update, :delete, :end_game, :start_test, :finish_test, :hand_over]
  before_action :ensure_editing_not_locked, only: [:edit, :update, :delete, :end_game, :start_test, :finish_test]
  before_action :ensure_game_was_not_started, only: [:edit, :update]
  before_action :require_superadmin!, only: [:withdraw, :restore, :unfinish, :lock, :unlock]

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
    @game.current_run.passings.each(&:end!)
    record_admin_action("end_game", @game) if acting_as_operator?(@game)
    redirect_to dashboard_path
  end

  # save, not save!. start_test sets is_draft to false, which is exactly the
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
    @game.is_draft = false
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

  def withdraw
    @game.withdraw!
    record_admin_action("withdraw", @game)
    redirect_to admin_games_path, :notice => t("games.withdrawn_notice")
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
    # ensure_author_if_game_is_draft, so redirecting to a game the caller has
    # just stopped authoring would answer a successful transfer with 401.
    redirect_to games_path, :notice => t("games.hand_over.done", :nickname => successor.nickname)
  end

  # Same treatment as start_test. This direction sets is_draft back to true so
  # the gate cannot fire, but another validation still can -- and an author
  # stuck in test mode with a blank 422 has no way to understand why.
  def finish_test
    @game.is_draft = true
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
    GamePassing.where(:game_run_id => @game.current_run.id).delete_all
    Log.of_run(@game.current_run).delete_all

    # After the two deletions above, deliberately: Team#deletable? refuses a
    # team that still holds a passing or a log line, so sweeping first would
    # spare every disposable team this test created.
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
                   :max_team_number, :is_draft, :primary_locale,
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
  def game_attributes
    attributes = game_params.to_h
    translations = attributes.delete("translations")
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

  def game_is_draft?
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
  def ensure_author_if_game_is_draft
    ensure_author if game_is_draft?
  end

  def ensure_author_if_no_start_time
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
end
