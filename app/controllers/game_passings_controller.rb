# -*- encoding : utf-8 -*-
class GamePassingsController < ApplicationController
  include SecurityFilters

  before_action :find_game
  # Authentication first: find_team dereferences current_user, so running it
  # before this filter turned a guest's request into a 500.
  before_action :require_authentication!, except: [:index, :show_results]
  before_action :find_team, except: [:show_results, :index]
  before_action :find_or_create_game_passing, except: [:show_results, :index]
  before_action :ensure_game_is_started
  before_action :ensure_team_captain, only: [:exit_game]
  before_action :ensure_game_not_finished_by_author, except: [:index, :show_results]
  before_action :ensure_team_not_exited, except: [:index, :show_results]
  before_action :ensure_team_member, except: [:index, :show_results]
  before_action :ensure_not_author_of_the_game, except: [:index, :show_results]
  before_action :ensure_author, only: [:index]
  before_action :ensure_game_not_paused, only: [ :post_answer, :exit_game ]

  # TICKET #83 ("Игрок удачно обновляется при завершении игры"): a team that
  # has finished has no current_level, so rendering show_current_level for one
  # raised NoMethodError on nil at
  # app/views/game_passings/show_current_level.html.erb:5 -- i.e. refreshing the
  # page at game end 500'd. #post_answer already had exactly this guard (see
  # below); GET simply never got it, in the Merb original as much as here. The
  # scenario that is supposed to cover this,
  # features/tickets/ticket-83(5).feature:29, could not see the bug because the
  # "я обновляю страницу" step was an empty no-op -- it is implemented now
  # (features/game-passing/steps/game-passing_steps.rb), so that scenario is a
  # real regression test for the first time.
  #
  # Same predicate, same template and the same default-layout choice as
  # #post_answer, so a team that has NOT finished is unaffected.
  def show_current_level
    if @game_passing.finished?
      render :show_results
      return
    end

    @game_passing.current_level = preloaded_level(@game_passing.current_level)
    @level = @game_passing.current_level
    render layout: "in_game"
  end

  def index
    @game_passings = GamePassing.of_game(@game)
    # For the move control on each row. Loaded once here rather than per row.
    @levels = Level.of_game(@game).order(:position)
  end

  # This is the live delivery path: level_hint_updater.js polls this route and
  # injects hint_text straight into the page as each countdown elapses, so a
  # hint unlocked after the initial page load never goes through
  # show_current_level.html.erb's translated() render at all. Translating
  # only the view left every hint but the ones already elapsed at page load
  # in the wrong language for a non-primary-locale player.
  def get_current_level_tip
    @game_passing.current_level = preloaded_level_for_tip(@game_passing.current_level)

    next_hint = @game_passing.upcoming_hints.first
    hint = @game_passing.hints_to_show.last
    content_locale = content_locale_for(@game_passing.game)

    render json: { hint_num: @game_passing.hints_to_show.length,
                    hint_text: hint&.translated(:text, content_locale),
                    next_available_in: next_hint&.available_in(@game_passing.current_level_entered_at, @game_passing.effective_now) }
  end

  def post_answer
    if @game_passing.finished?
      render :show_results
      return
    end

    # A quiz level submits picked options, not a typed string. Everything below
    # is the code path exactly as it was, and a level with no options never
    # reaches the branch.
    return post_options if @game_passing.current_level.quiz?

    # params[:answer] is a bare string. Guard the type: a crafted request
    # sending answer[value]=... made the Merb app raise on String#strip.
    # Stripped up front (matching the Merb original) rather than relying on
    # GamePassing#check_answer!'s internal strip!, which mutates in place --
    # save_log below must see the trimmed value, same as the original.
    raw_answer = params[:answer]
    @answer = raw_answer.is_a?(String) ? raw_answer.strip : ""
    save_log
    @answer_was_correct = @game_passing.check_answer!(@answer)

    if @game_passing.finished?
      render :show_results
    else
      # check_answer! may have advanced current_level (pass_level!), so the
      # preload has to happen after it, same as show_current_level -- this
      # render path shows the same view and reads translated() the same way.
      @game_passing.current_level = preloaded_level(@game_passing.current_level)
      render :show_current_level, layout: "in_game"
    end
  end

  def show_results
  end

  def exit_game
    @game_passing.exit!
    render :show_results
  end

  # Writes on behalf of current_user, which require_authentication! (see the
  # before_action list above) already guarantees is present for every action
  # on this controller except :index and :show_results -- but that filter's
  # job is authentication, not this action's, so still check rather than
  # trust it silently and let a future filter change turn this into a
  # NoMethodError on nil instead of a no-op.
  def set_content_locale
    if current_user && @game.available_locale_list.include?(params[:locale].to_s)
      preference = GameLocalePreference.find_or_initialize_by(:user_id => current_user.id,
                                                             :game_id => @game.id)
      preference.locale = params[:locale].to_s
      preference.save!
    end
    redirect_to show_current_level_path(:game_id => @game.id)
  end

  private

  # Quiz levels submit option_ids as { question_id => [option_id, ...] }.
  #
  # Each question is judged independently: getting one right and one wrong
  # marks the first answered and charges one penalty, rather than discarding
  # both. That falls out of the existing model -- all_questions_answered? is
  # already what advances a level.
  #
  # The log records the chosen option texts, so the author's answer log stays a
  # complete account of what teams did, exactly as it is for typed codes.
  def post_options
    # A crafted request can send option_ids as a bare scalar (option_ids=boom),
    # which has no #each. Only a real params Hash behaves as a selection;
    # anything else is treated as no selection at all.
    selections = params.fetch(:option_ids, {})
    selections = {} unless selections.is_a?(ActionController::Parameters) || selections.is_a?(Hash)

    chosen_texts = []
    selections.each do |question_id, option_ids|
      chosen_texts.concat(Option.where(:id => Array(option_ids)).pluck(:text))
    end

    # A level may hold both kinds of question. Without this the typed answer is
    # silently discarded and a mixed level can never be completed.
    typed = params[:answer]
    typed = typed.is_a?(String) ? typed.strip : ""
    chosen_texts << typed if typed.present?

    # Logged, and against the level the answer was actually submitted on --
    # before any of the calls below can advance current_level via pass_level!,
    # which save_log's current_level read would otherwise see already moved.
    # Matches the code path in #post_answer, which calls save_log before
    # check_answer! for the same reason.
    @answer = chosen_texts.join(", ")
    save_log

    results = []
    selections.each do |question_id, option_ids|
      question = @game_passing.current_level.questions.find_by(:id => question_id)
      next unless question

      results << @game_passing.answer_options!(question, option_ids)
    end
    results << @game_passing.check_answer!(typed) if typed.present?

    @answer_was_correct = results.any? && results.all?

    if @game_passing.finished?
      render :show_results
    else
      # answer_options! may have advanced current_level, so preload after it --
      # same reasoning as the code path above.
      @game_passing.current_level = preloaded_level(@game_passing.current_level)
      render :show_current_level, layout: "in_game"
    end
  end

  # PORT DEFECT, now fixed (found by
  # features/game-passing/throw_in_the_towel.feature): there used to be a second
  # finder, #find_game_by_id, used only by #exit_game and reading params[:id].
  # Merb reached #exit_game through the catch-all /:controller/:action/:id
  # route, so the game did arrive as params[:id] there -- but the Rails route
  # restored for it names the segment :game_id
  # ("/game_passings/exit_game/:game_id", config/routes.rb), as do the link that
  # drives it (app/views/game_passings/show_current_level.html.erb) and
  # spec/routing_spec.rb. Every "Сойти с дистанции" click therefore raised
  # RecordNotFound before the action ever ran. Once corrected the two finders
  # were byte-identical, so #exit_game just uses this one.
  # show_current_level.html.erb (and the identical post_answer render) reads
  # @game.translated(:name, content_locale) -- see Finding 2 of the
  # whole-branch review -- so this needs its own content_translations
  # preloaded too; @game_passing.current_level's preloaded :game (below) is a
  # different, separately-loaded Game object and does not cover this one.
  def find_game
    @game = Game.includes(:content_translations).find(params[:game_id])
  end

  def find_team
    @team = current_user.team
  end

  # translated() searches the loaded association rather than querying, so this
  # preload is what makes it O(1) per page instead of O(fields). Nested, not
  # sibling: includes(:hints, :questions, :content_translations) preloads
  # only the LEVEL's own translations and leaves each hint and question to
  # lazy-load its own -- one query per record (see the same tradeoff
  # documented on Game#translatable_records). :game is preloaded too, since
  # every translated() call resolves primary_locale through it; Rails'
  # automatic inverse_of means each preloaded hint/question's `level` is this
  # same object, so this one row covers all of them.
  def preloaded_level(level)
    # :options is nested under :questions, not a sibling -- Level#quiz? asks
    # every question whether it has options, and each option's text is rendered
    # through translated(). Without this the play view fires one query per
    # question and another per option, which is exactly what
    # spec/requests/translated_level_spec.rb's query-count guard exists to catch.
    Level.includes(:game, :content_translations,
                   :hints => :content_translations,
                   :questions => [ :content_translations,
                                   { :options => :content_translations } ]).find(level.id)
  end

  # Same reasoning as preloaded_level, deliberately narrower: every playing
  # team polls #get_current_level_tip repeatedly, and this JSON response
  # never includes level or question text, so there's no reason to pay for
  # loading (or translating) either -- just the hints and the :game a
  # translated() call on one of them needs to resolve primary_locale.
  def preloaded_level_for_tip(level)
    Level.includes(:game, :hints => :content_translations).find(level.id)
  end

  # TODO: must be a critical section, double creation is possible!
  def find_or_create_game_passing
    @game_passing = GamePassing.of(@team, @game) ||
                    GamePassing.create!(team: @team, game: @game,
                                         current_level: @game.levels.first)
  end

  def save_log
    return unless @game_passing.current_level&.id

    level = Level.find(@game_passing.current_level.id)
    Log.create!(game_id: @game.id, level: level.name, team: @team.name,
                time: Time.now, answer: @answer)
  end

  def ensure_game_is_started
    return if @game.is_testing?
    raise Authentication::Unauthorized, t("game.not_started") unless @game.started?
  end

  def ensure_not_author_of_the_game
    return if @game.is_testing?
    raise Authentication::Unauthorized, t("errors.cannot_play_own_game") if @game.created_by?(current_user)
  end

  def ensure_game_not_finished_by_author
    raise Authentication::Unauthorized, t("errors.game_finished_by_author") if @game.author_finished?
  end

  def ensure_team_not_exited
    raise Authentication::Unauthorized, t("errors.team_exited") if @game_passing.exited?
  end

  # Deliberately NOT an Authentication::Unauthorized like its neighbours here.
  # A paused game is a normal temporary state, not an authorization failure,
  # and telling a player they are not allowed to play their own game would be
  # both confusing and untrue. show_current_level is not in this list: the
  # player keeps seeing their level with a banner over it.
  def ensure_game_not_paused
    return unless @game.paused?

    redirect_to show_current_level_path(:game_id => @game.id),
                :alert => t("game_passings.paused")
  end
end
