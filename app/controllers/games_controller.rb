# -*- encoding : utf-8 -*-
class GamesController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!, except: [:index, :show]
  before_action :find_game, only: [:show, :edit, :update, :delete, :end_game, :start_test, :finish_test, :withdraw, :restore, :lock, :unlock]
  before_action :find_team, only: [:show]
  before_action :ensure_author_if_game_is_draft, only: [:show]
  before_action :ensure_author_if_no_start_time, only: [:show]
  before_action :ensure_author_if_game_is_withdrawn, only: [:show]
  before_action :ensure_author, only: [:edit, :update, :delete, :end_game, :start_test, :finish_test]
  before_action :ensure_editing_not_locked, only: [:edit, :update, :delete, :end_game, :start_test, :finish_test]
  before_action :ensure_game_was_not_started, only: [:edit, :update]
  before_action :require_superadmin!, only: [:withdraw, :restore, :lock, :unlock]

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
               games
             else
               Game.visible
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
    @game_entries = GameEntry.of_game(@game).with_status("new")
    @teams = GameEntry.of_game(@game).with_status("accepted").map(&:team)
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

  def end_game
    @game.finish_game!
    GamePassing.of_game(@game).each(&:end!)
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
    @game.registration_deadline = nil

    unless @game.save
      redirect_to @game, :alert => @game.errors.full_messages.to_sentence and return
    end

    record_admin_action("start_test", @game) if acting_as_operator?(@game)
    redirect_to @game
  end

  def withdraw
    @game.update!(:withdrawn_at => Time.now)
    record_admin_action("withdraw", @game)
    redirect_to admin_games_path, :notice => t("games.withdrawn_notice")
  end

  def restore
    @game.update!(:withdrawn_at => nil)
    record_admin_action("restore", @game)
    redirect_to admin_games_path, :notice => t("games.restored_notice")
  end

  def lock
    @game.update!(:editing_locked_at => Time.now)
    record_admin_action("lock", @game)
    redirect_to admin_games_path, :notice => t("games.locked_notice")
  end

  def unlock
    @game.update!(:editing_locked_at => nil)
    record_admin_action("unlock", @game)
    redirect_to admin_games_path, :notice => t("games.unlocked_notice")
  end

  # Same treatment as start_test. This direction sets is_draft back to true so
  # the gate cannot fire, but another validation still can -- and an author
  # stuck in test mode with a blank 422 has no way to understand why.
  def finish_test
    @game.is_draft = true
    @game.is_testing = false
    @game.starts_at = @game.test_date
    @game.test_date = Time.now

    unless @game.save
      redirect_to @game, :alert => @game.errors.full_messages.to_sentence and return
    end

    GamePassing.of_game(@game).delete_all
    Log.of_game(@game).delete_all

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
