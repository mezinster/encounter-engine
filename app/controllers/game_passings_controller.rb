# -*- encoding : utf-8 -*-
class GamePassingsController < ApplicationController
  include SecurityFilters

  before_action :find_game
  # Authentication first: find_team dereferences current_user, so running it
  # before this filter turned a guest's request into a 500.
  before_action :require_authentication!, except: [:index, :show_results]
  before_action :find_team, except: [:show_results, :index]
  # find_or_create_game_passing moved below ensure_game_is_started and
  # ensure_game_not_finished_by_author (both check only @game, set by
  # find_game above) -- it depends on nothing before it except @team, and
  # every filter that depends on @game_passing (ensure_team_not_exited
  # onward) already sits after it.
  #
  # It used to run right after find_team, ahead of ensure_game_is_started.
  # An accepted team could GET /play/:game_id before starts_at: the row got
  # created, before_create :update_current_level_entered_at (GamePassing)
  # stamped the hint clock at that early moment, and only then did
  # ensure_game_is_started 401. Nothing restamps the clock at the real start
  # -- Game#resume! is the only other writer of that column -- so at kickoff
  # the early-loader's hints_to_show already read every level-1 hint whose
  # delay had "elapsed" against the wrong start time, handing them out
  # instantly while honest teams waited. The same root cause produced a
  # phantom, still-ticking level-1 row if an accepted team hit /play after
  # end_game. Pinned by
  # spec/requests/game_registration_enforcement_spec.rb ("creates no passing
  # when an accepted team plays before the game starts").
  # Before ensure_game_is_started, deliberately: that guard has to know WHICH
  # run is being looked at. Opening a run gives the game a future start date,
  # and without this the results page of an already-finished run would be
  # refused as "the game has not started yet" -- the one thing this whole
  # programme exists to keep readable.
  before_action :find_run, only: [:show_results]
  before_action :ensure_game_is_started
  before_action :ensure_team_captain, only: [:exit_game]
  before_action :ensure_game_not_finished_by_author, except: [:index, :show_results]
  before_action :find_or_create_game_passing, except: [:show_results, :index]
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
      @run ||= @game.current_run
      render :show_results
      return
    end

    @game_passing.current_level = preloaded_level(@game_passing.current_level)
    @level = @game_passing.current_level
    render layout: "in_game"
  end

  def index
    @game_passings = @game.current_run.passings
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
                    # Platform chrome, so it goes through t() like the
                    # server-rendered legend does -- NOT hardcoded in
                    # level_hint_updater.js. Fixes a pre-existing bug: the JS
                    # used to hardcode the Russian literal "Подсказка"
                    # regardless of the interface locale, so a hint that
                    # unlocked after page load showed one Russian word to
                    # every non-Russian player. See appendHint in
                    # public/javascripts/level_hint_updater.js.
                    hint_label: t("game_passings.show_current_level.hint_label"),
                    # For the attachment strip's aria-label, matching
                    # shared/_attachment_strip.html.erb's role="group" +
                    # aria-label pairing -- same reasoning as hint_label
                    # above: platform chrome, translated server-side, never
                    # hardcoded in the JS that renders it.
                    attachments_label: t("game_passings.show_current_level.attachments_label"),
                    attachments: hint_attachments_json(hint, content_locale),
                    next_available_in: next_hint&.available_in(@game_passing.current_level_entered_at, @game_passing.effective_now) }
  end

  def post_answer
    if @game_passing.finished?
      @run ||= @game.current_run
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
    stripped_answer = raw_answer.is_a?(String) ? raw_answer.strip : ""

    # An empty code box submits @answer = "" -- this level has no quiz
    # question, so there is nothing else it could be. Production logged this
    # silently (14 blank rows on game 4's full log: no scoring, no feedback,
    # just the page again -- one team hit it three times in eleven seconds).
    # The owner's call: refuse it with a message rather than writing a blank
    # row nobody asked to submit.
    if stripped_answer.blank?
      reject_empty_answer(:code)
      return
    end

    @answer = stripped_answer
    @answer_kind = :code
    save_log
    # check_answer! may call pass_level!, and the render below then shows the
    # NEXT level with @answer still describing this one -- see #note_level_passed.
    level_before = @game_passing.current_level
    @answer_was_correct = @game_passing.check_answer!(@answer)
    note_level_passed(level_before)

    if @game_passing.finished?
      @run ||= @game.current_run
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
    # These renders reach show_results.html.erb WITHOUT going through
    # #show_results, so find_run never ran for them. The current run is right
    # here: a team that has just finished or exited is in the run being played,
    # never an earlier one.
    #
    # find_run stays scoped to #show_results deliberately -- widening it would
    # let ensure_game_is_started judge a PLAY request against an older, started
    # run, and admit a team into a run that has not opened yet.
    @run ||= @game.current_run
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
  # both. That falls out of the existing model -- level_answered? is
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
      # Scoped to this level's questions. Unscoped, this was a read oracle over
      # the whole options table: a crafted question_id matches nothing in the
      # scoring loop below, so no penalty was charged and nothing changed -- but
      # the plucked text still reached the player through @answer and the
      # answer_incorrect message, and was written to the author's log. Ids for
      # levels the team had not reached, and for other games, all resolved.
      chosen_texts.concat(
        Option.where(:id => Array(option_ids),
                     :question_id => @game_passing.current_level.questions.select(:id)).pluck(:text))
    end

    # A level may hold both kinds of question. Without this the typed answer is
    # silently discarded and a mixed level can never be completed.
    typed = params[:answer]
    typed = typed.is_a?(String) ? typed.strip : ""
    chosen_texts << typed if typed.present?

    # Nothing picked and nothing typed -- exactly what pressing "Отправить!"
    # with no selection produces (params[:option_ids] is simply absent).
    # Production logged this as a blank row with no scoring and no feedback
    # (game 4's full log, 14 rows); the owner's call is to refuse it instead.
    # chosen_texts already folds the typed answer in above, so this single
    # check covers a pure quiz level and a mixed quiz-and-code level alike.
    if chosen_texts.empty?
      reject_empty_answer(:choice)
      return
    end

    # Logged, and against the level the answer was actually submitted on --
    # before any of the calls below can advance current_level via pass_level!,
    # which save_log's current_level read would otherwise see already moved.
    # Matches the code path in #post_answer, which calls save_log before
    # check_answer! for the same reason.
    @answer = chosen_texts.join(", ")
    # A mixed level can carry both kinds at once. "Code" is the honest word the
    # moment a typed code is part of the submission; only a pure selection gets
    # the choice wording.
    @answer_kind = typed.present? ? :code : :choice
    save_log

    level_before = @game_passing.current_level
    results = []
    selections.each do |question_id, option_ids|
      # Restricted to unanswered_questions, not current_level.questions: the
      # view only offers unanswered questions (see
      # show_current_level.html.erb), but a crafted request can still submit
      # option_ids for one already answered. Without this guard, a wrong pick
      # on an already-answered question would charge wrong_answer_penalty a
      # second time for a question the team already got right.
      question = @game_passing.unanswered_questions.detect { |q| q.id.to_s == question_id.to_s }
      next unless question

      results << @game_passing.answer_options!(question, option_ids)
    end
    results << @game_passing.check_answer!(typed) if typed.present?

    @answer_was_correct = results.any? && results.all?
    note_level_passed(level_before)

    if @game_passing.finished?
      @run ||= @game.current_run
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

  # The ORDINAL, not the id: stable, human-readable, and meaningful in a URL a
  # player might share. Absent, unknown or malformed falls back to the current
  # run rather than 404ing -- a stale bookmark should show the current
  # standings, not an error.
  def find_run
    @run = @game.runs.find_by(:ordinal => run_ordinal) || latest_started_run
  end

  # `?run=2` arrives as a String; `?run[x]=1`/`?run[]=1` arrive as an
  # ActionController::Parameters/Array, neither of which responds to #to_i --
  # pre-existing 500 on a mistyped URL here, same bug as
  # FileDeliveriesController#requested_run (review fix, Task 5 round; see
  # that method's comment for the full reasoning). This route carries no id
  # to enumerate, so it was never an oracle, but a malformed :run shouldn't
  # 500 any more than a malformed one should here either. nil for anything
  # that isn't a String: find_by(:ordinal => nil) matches no run (ordinal is
  # a required column), so this falls through to latest_started_run exactly
  # as a blank/bogus ordinal already did.
  def run_ordinal
    params[:run].to_i if params[:run].is_a?(String)
  end

  # The latest run that has actually STARTED, not simply the current one.
  #
  # Opening a run gives a game a future start date, so defaulting to the
  # current run would answer "the game has not started yet" the moment an
  # operator schedules a rerun -- hiding the standings of the run that just
  # finished, from the page whose whole job is to show them.
  #
  # Falls back to the current run when none has started, which is what a game
  # awaiting its first run needs; the started-run guard then refuses, exactly
  # as it did before any of this existed.
  def latest_started_run
    @game.runs.to_a.reverse.detect { |run| run.starts_at.present? && Time.now > run.starts_at } ||
      @game.current_run
  end

  # A solo test participant plays in a DISPOSABLE team they are not a member
  # of, so current_user.team -- which reads users.team_id -- is the wrong
  # answer for them and the right one for everybody else.
  #
  # Safe to consult @game.current_run here: find_game already runs first (:5
  # before :9), so this needs no change to the filter order, whose comment
  # documents a hint-clock bug caused by moving a filter in this chain.
  def find_team
    @team = test_admission&.team || current_user.team
  end

  # nil unless this game is in test mode AND the current user holds a SOLO
  # admission in its current run. Memoised because find_team and
  # ensure_team_member each ask, and a real team's admission (user_id NULL)
  # deliberately does not match -- its members already resolve through
  # current_user.team.
  def test_admission
    return nil unless @game&.is_testing?

    @test_admission ||= TestAdmission.find_by(:game_run_id => @game.current_run.id,
                                              :user_id     => current_user.id)
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
    #
    # :file_attachments => { :game_file => [...] }, added for the attachment
    # strip (Task 3), on both the level and each hint. Four things this
    # feeds, all otherwise N+1 across hints and across files:
    #   1. FileAttachable#attached_files_for reads the loaded
    #      `file_attachments` array in Ruby instead of re-querying, when it
    #      finds one preloaded -- see that method's comment. Without this,
    #      the play screen paid one extra query per HINT (confirmed:
    #      spec/requests/translated_level_spec.rb's flat-query-count guard
    #      went from equal to +9 on a 10-hint page the moment this render was
    #      added, before this preload existed).
    #   2. game_file_delivery_path (shared/_attachment_strip.html.erb) reads
    #      file.game for the URL -- free once nested here.
    #   3. GameFileAccess#permitted? reads file.game.current_run
    #      (game.rb's `runs.to_a.last`) as part of its own authorization
    #      check -- free once `:runs` is nested this deep. permitted? still
    #      queries file_attachments+attachable and passing_for(team) itself
    #      on every call (its own class comment explains why: `.includes`
    #      called on an association always discards a preload, so this is
    #      NOT avoidable from the caller's side).
    #   4. GameFile#existing_web_variant's `file.attached?` and
    #      `file.variant(...).image` -- Attached::One#attached? reads
    #      `file_attachment`, and ActiveStorage::VariantWithRecord#record
    #      (private) checks `blob.variant_records.loaded?` and, when true,
    #      resolves via Ruby #find instead of #find_by -- see that method in
    #      the activestorage gem. `:file_attachment => { :blob =>
    #      { :variant_records => { :image_attachment => :blob } } }` is what
    #      makes both loaded: the attachment itself, its blob, that blob's
    #      variant records, and each variant record's own image attachment
    #      (+ blob), which is what url/key generation for the <img> reads.
    #      Measured over real HTTP (task-3-report.md, Important 3 follow-up):
    #      10 files on one level went from 103 to 68 queries; an 11-file page
    #      (10 hints x 1 file + 1 level file) went from 153 to 114.
    Level.includes(:game, :content_translations,
                   :file_attachments => { :game_file => [
                     { :game => :runs },
                     { :file_attachment => { :blob => { :variant_records => { :image_attachment => :blob } } } }
                   ] },
                   :hints => [ :content_translations,
                               { :file_attachments => { :game_file => [
                                 { :game => :runs },
                                 { :file_attachment => { :blob => { :variant_records => { :image_attachment => :blob } } } }
                               ] } } ],
                   :questions => [ :content_translations,
                                   { :options => :content_translations } ]).find(level.id)
  end

  # Same reasoning as preloaded_level, deliberately narrower: every playing
  # team polls #get_current_level_tip repeatedly, and this JSON response
  # never includes level or question text, so there's no reason to pay for
  # loading (or translating) either -- just the hints and the :game a
  # translated() call on one of them needs to resolve primary_locale.
  #
  # Task 4 addition: the same :file_attachments => { :game_file => [...] }
  # nesting preloaded_level uses, but only under :hints -- this route never
  # renders the LEVEL's own attachment strip (that already reached the page
  # at load time, in show_current_level.html.erb), only whichever hint just
  # fired. Three things it buys here, per hint: attached_files_for reads the
  # loaded array instead of re-querying, game_file_delivery_path's file.game
  # is free, and existing_web_variant's variant-record lookup is free.
  #
  # NOT free, despite the same nesting: GameFileAccess#permitted?'s OWN
  # `file.game.current_run` read (game_file_access.rb's passing_for_game) is
  # free, but permitted? goes on to call hint_visible?, which reads
  # `passing.hints_to_show` -- and that `passing` is a GamePassing fetched
  # fresh by passing_for_game, whose OWN game (reached through its game_run,
  # not through this preloaded tree) is a separate, unpreloaded object. Its
  # `effective_now` calls `game.paused_at`, which Game delegates to
  # `current_run`, and THAT current_run re-queries game_runs -- once per
  # attached file, confirmed empirically (game_runs went from 4 to 8 queries
  # between 1 and 5 attachments on an otherwise-identical request). This is
  # why this route measures ~8 queries/attachment rather than the ~4/file
  # preloaded_level reaches for show_current_level -- see
  # spec/requests/attachment_query_cost_spec.rb's /tip guard, which pins the
  # ~8/file rate this preload does achieve (down from ~14/file without it)
  # rather than a number this preload was never going to reach alone.
  def preloaded_level_for_tip(level)
    Level.includes(:game,
                    :hints => [ :content_translations,
                                { :file_attachments => { :game_file => [
                                  { :game => :runs },
                                  { :file_attachment => { :blob => { :variant_records => { :image_attachment => :blob } } } }
                                ] } } ]).find(level.id)
  end

  # The attachments the JSON poller may hand the just-fired hint --
  # exactly the files the server-rendered strip would show, gated by the
  # same GameFileAccess#permitted? question (see shared/_attachment_strip.html.erb's
  # comment on why that check runs per file rather than being trusted from
  # further up the call chain). `hint` here is ALWAYS
  # @game_passing.hints_to_show.last -- the hint that just fired -- never a
  # hint from upcoming_hints, so a hint's files become visible in this
  # payload exactly when the hint itself does, not before.
  #
  # {url:, alt:} at minimum per the task brief; image_url is added and left
  # nil for a PDF, a GIF, or an image with no existing web variant -- the
  # same three cases shared/_attachment_strip.html.erb degrades to a
  # generic link for, via existing_web_variant (deliberately NOT
  # web_variant, which GENERATES on a miss -- see that method's comment and
  # design invariant I1). level_hint_updater.js's appendHint reads image_url
  # to decide whether to build an <img> or a generic link, matching that
  # same degradation client-side.
  #
  # KNOWN LIMITATION, not fixed here: only the LAST fired hint's attachments
  # are ever returned, same as hint_text above it in the render call. If two
  # hints fire between polls (a short delay on one, a slow poll interval, a
  # tab left in the background), the earlier hint's photographs never reach
  # the page -- not late, not on the next poll, not until the player reloads.
  # This has always been true of hint_text; it now also applies to
  # attachments, where the photograph is frequently the hint that actually
  # matters. Pre-existing shape, carried forward rather than restructured.
  def hint_attachments_json(hint, content_locale)
    return [] if hint.nil?

    hint.attached_files_for(content_locale)
        .select { |file| GameFileAccess.new(current_user, file).permitted? }
        .map do |file|
          { url: game_file_delivery_path(@game, file, "original"),
            image_url: (game_file_delivery_path(@game, file, "web") if file.existing_web_variant.present?),
            alt: file.filename }
        end
  end

  # TODO: must be a critical section, double creation is possible!
  #
  # Registration is checked HERE, at creation, and deliberately not in a
  # before_action. Two consequences, both wanted:
  #
  # 1. An existing passing is served unchanged. A team that is already playing
  #    must not be locked out because their entry status changed underneath
  #    them -- the gate is on starting a game, not on continuing one.
  # 2. The nil-team case is refused before anything is written. This filter
  #    used to run at chain position 4 while ensure_team_member ran at position
  #    8, so a team-less user's 401 still left a GamePassing with team_id NULL
  #    behind it -- and game_passings/index.html.erb:65 and
  #    show_results.html.erb:61 both dereference game_passing.team.name, so
  #    that row permanently 500'd the author's stats page and the public
  #    results page, with no UI able to delete it.
  #
  # Before this, registration was enforced only in
  # shared/_current_games_status.html.erb, which hides the "Играть!" link for a
  # non-accepted entry but stops nothing: any user could create a team and GET
  # /play/:game_id for any started game, including one the author had
  # explicitly rejected.
  def find_or_create_game_passing
    @game_passing = @game.current_run.passing_for(@team)
    return @game_passing if @game_passing

    unless may_start_passing?
      raise Authentication::Unauthorized, t("errors.not_registered_for_game")
    end

    @game_passing = GamePassing.create!(team: @team, game: @game,
                                        game_run: @game.current_run,
                                        current_level: @game.levels.first)
  end

  # is_testing? is exempt, but ONLY for the author's own team, and that
  # exemption is load-bearing: the author's team plays test mode with no
  # GameEntry by construction (features/games/test-game-1.feature and
  # test-game-2.feature both fail without this). It must not extend to any
  # other team: ensure_game_is_started and ensure_not_author_of_the_game both
  # also return early on is_testing?, so an unscoped exemption here would let
  # any authenticated user self-register a team and read every level and
  # answer code of an unstarted, unregistered game -- including one whose
  # entry the author had rejected -- before the game ever goes live.
  # GameEntry.of dereferences team.id, so the nil check must come first.
  def may_start_passing?
    return false if @team.nil?
    return true if @game.is_testing? && @game.created_by?(current_user)

    # Covers BOTH invitee kinds with one lookup, because an admission always
    # names a team: a real team's admission names itself, a solo admission
    # names the disposable team find_team has already resolved into @team.
    return true if @game.is_testing? &&
                   TestAdmission.exists?(:game_run_id => @game.current_run.id,
                                         :team_id     => @team.id)

    GameEntry.of(@team, @game.current_run)&.status == "accepted"
  end

  # SecurityFilters#ensure_team_member asks users.team_id, which is exactly
  # what a solo test participant does not have and must not be given -- so
  # without this it 401s them AFTER the admission, the disposable team and
  # find_team have all worked correctly.
  #
  # This method overrides the module's (a class's own method wins over an
  # included module's) and `super` reaches it for everyone else. Scoped to
  # "holds an admission in this testing run", never to is_testing? broadly:
  # the latter would drop the check for every stranger the moment a game
  # entered test mode.
  def ensure_team_member
    return if test_admission

    super
  end

  # Shared by post_answer and post_options: a submission with nothing typed
  # and nothing selected is refused outright rather than logged -- no
  # save_log, no scoring, just the same show_current_level render every other
  # non-advancing submission gets. @answer is left nil (answer_posted? stays
  # false), and @answer_rejected drives the new alert instead
  # (GamePassingsHelper#answer_rejected? / #rejected_answer_message).
  def reject_empty_answer(kind)
    @answer_rejected = kind
    @game_passing.current_level = preloaded_level(@game_passing.current_level)
    render :show_current_level, layout: "in_game"
  end

  # Both post actions render show_current_level after scoring, and scoring may
  # have advanced the team. When it has, the page on screen asks a DIFFERENT
  # question from the one @answer answered, and «Код 'Рецепт суши' -- верный»
  # sat pinned under a question about penicillin, reading as feedback on the
  # question in front of the team rather than the one behind it.
  #
  # The message cannot simply be suppressed in that case:
  # features/game-passing/stepping-next-level.feature:26-27 is frozen and
  # requires it AND "Задание #2" on the same rendered page. So the view is
  # told which level was passed instead, and says so.
  #
  # Left nil when nothing moved -- a correct code on a level with another code
  # still to find is feedback on the question actually on screen, and must
  # neither be relabelled nor dismissed. Also left nil when the game ended:
  # that renders show_results, which has no flash to label.
  def note_level_passed(level_before)
    return if level_before.nil? || @game_passing.finished?
    return if @game_passing.current_level&.id == level_before.id

    @level_passed = level_before
  end

  def save_log
    return unless @game_passing.current_level&.id

    level = Level.find(@game_passing.current_level.id)
    # game_run_id from the PASSING, not from @game.current_run: the passing is
    # what this answer actually belongs to, and in phase 3 a team's passing may
    # be in a run that is no longer the current one.
    Log.create!(game_id: @game.id, game_run_id: @game_passing.game_run_id,
                level: level.name, level_id: level.id,
                team: @team.name,  team_id: @team.id,
                time: Time.now, answer: @answer)
  end

  def ensure_game_is_started
    return if @game.is_testing?
    raise Authentication::Unauthorized, t("game.not_started") unless viewing_a_started_run?
  end

  # Game#started? asks about the CURRENT run. That is right for every action
  # that plays the game, and wrong for show_results once a second run exists:
  # run 2 has not started, but run 1 finished months ago and its standings must
  # stay readable.
  #
  # The draft check is kept from Game#started? -- an unpublished game has not
  # begun whatever the clock says (see the comment there).
  def viewing_a_started_run?
    return @game.started? if @run.nil?

    # GameRun#results_visible? is the single definition of this rule; the
    # results switcher decides what to link with the same call, so the page
    # cannot offer a link this guard would refuse.
    @run.results_visible?
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
