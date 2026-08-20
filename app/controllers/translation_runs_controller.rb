# -*- encoding : utf-8 -*-
#
# Superadmin-triggered AI translation of a game's author-written content.
#
# The run happens in a Thread rather than a job: this application has no
# ActiveJob backend (:inline in all three environments) and the production host
# has one vCPU and roughly 1.1 GB spare, so a queue backend would cost a second
# container for a feature used a few times a week. Progress is persisted per
# field instead, which is what makes a killed thread resumable.
class TranslationRunsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!
  before_action :load_game
  # :new and :create ONLY. The sweep's own justification is that "the only
  # moment a stale run actually matters is when someone tries to start a new
  # one" -- and unqualified it also ran on #show, the page whose
  # <meta http-equiv="refresh" content="3"> reloads every three seconds. That
  # turned a latent bug into a guaranteed one: fifteen minutes into any run the
  # operator's own progress page marked their healthy run `failed`, which is
  # not an ACTIVE_STATE, which released the partial unique index, which let
  # them start a SECOND run against the same game and the same key while the
  # first thread was still calling.
  before_action :sweep_stale_runs, :only => [ :new, :create ]
  before_action :require_api_key!

  def new
    @locales = I18n.available_locales.map(&:to_s) - [ @game.primary_locale.to_s ]
  end

  def create
    locales = Array(params[:locales]).map(&:to_s) & I18n.available_locales.map(&:to_s)
    work    = Translation::Runner.plan(@game, locales)

    return refuse("empty")           if work.empty?
    return refuse("already_running") if TranslationRun.active_for(@game).exists?
    return refuse("too_large", :count => Setting.integer("translation_max_fields_per_run")) if
      work.size > Setting.integer("translation_max_fields_per_run")

    # The cost guard the design names first among three, "free and exact -- no
    # guessing". Without it the edit screen's one-click button starts spending
    # immediately and estimated_input_tokens is a dead column. This app has no
    # JavaScript (adopting Turbo is an explicit non-goal), so the confirmation
    # is a second POST carrying a hidden `confirmed` field.
    return render_confirmation(locales, work) unless params[:confirmed].present?

    run = begin
            TranslationRun.create!(
              :game => @game, :actor => current_user,
              # Frozen here, deliberately: reading the Setting live would let a
              # change mid-run produce proposals from two models with no way
              # to tell which.
              :model => Setting.enum("translation_model"),
              :state => TranslationRun::PENDING,
              :target_locale_list => locales,
              :fields_total => work.size,
              # Carried from the confirmation screen rather than recomputed.
              #
              # The reason originally given here was that count_tokens is one
              # round trip per unit per locale -- true when written, and no
              # longer: Runner.estimate_input_tokens now batches into one
              # baseline call per locale plus bulk calls, precisely so a large
              # multi-locale game could not 502 the confirmation screen.
              #
              # It is still not recomputed, for a reason that survives: the
              # figure is informational, it drives no decision at this point,
              # and re-running the pre-flight would spend real API calls to
              # produce a number nobody reads twice. Only a superadmin can
              # reach this action, so a hand-edited value costs nothing.
              :estimated_input_tokens => params[:estimated_input_tokens].to_i
            )
          rescue ActiveRecord::RecordNotUnique
            # Lost the race against a concurrent POST. The guard above passed
            # because no active run existed when it looked; the partial
            # unique index on translation_runs.game_id is what actually
            # enforces the invariant, and this is where losing lands. Same
            # message either way -- the operator does not need to know which
            # of the two paths refused them.
            return refuse("already_running")
          end

    start(run)
    record_admin_action("translation_run_started", @game,
                        "locales=#{locales.join(",")} fields=#{work.size} model=#{run.model}")
    redirect_to game_translation_run_path(@game, run)
  end

  def show
    @run = @game.translation_runs.find(params[:id])
  end

  def cancel
    run = @game.translation_runs.find(params[:id])
    # A terminal run has nothing left to cancel, and rewriting one destroys the
    # record: a succeeded run became `cancelled`, its finished_at was
    # restamped, and the audit log gained an entry for a cancellation that
    # cancelled nothing. The show page only offers Cancel while the run is
    # active, but a bare POST reached this either way.
    if run.terminal?
      flash[:alert] = t("translations.runs.already_finished")
      return redirect_to(game_translation_run_path(@game, run))
    end

    run.update!(:state => TranslationRun::CANCELLED, :finished_at => Time.now)

    record_admin_action("translation_run_cancelled", @game, "run=#{run.id}")
    redirect_to game_translation_run_path(@game, run)
  end

  # Re-enters an existing run instead of starting a new one, which is the
  # whole point: Runner#already_proposed? is scoped to THIS run's proposals, so
  # a fresh run would re-translate -- and re-pay for -- everything the failed
  # one already produced. The design says the run page offers Retry and that
  # retry and resumability "are the same mechanism"; the mechanism was built
  # and then had no caller.
  def retry
    run = @game.translation_runs.find(params[:id])

    # FAILED only. An active run must not be re-entered -- two threads on one
    # run would duplicate every call the unique index does not happen to
    # catch. A succeeded run has nothing outstanding. And a CANCELLED run is
    # deliberately excluded: cancelling is a human saying stop, and a button
    # that silently restarts it would make the stop unreliable; starting a new
    # run is the honest way back from a cancellation.
    unless run.state == TranslationRun::FAILED
      flash[:alert] = t("translations.runs.not_retryable")
      return redirect_to(game_translation_run_path(@game, run))
    end

    start(run)
    record_admin_action("translation_run_retried", @game,
                        "run=#{run.id} done=#{run.fields_done} of=#{run.fields_total}")
    redirect_to game_translation_run_path(@game, run)
  end

  private

  # Renders the estimate and re-offers the same POST with `confirmed` set.
  #
  # A failed pre-flight must not block the run: the estimate is a courtesy,
  # and refusing to translate because the free token count could not be
  # fetched would be the guard costing more than it saves. nil renders as
  # "unknown" on the screen.
  def render_confirmation(locales, work)
    @locales  = locales
    @work     = work
    @model    = Setting.enum("translation_model")
    @estimate = begin
                  Translation::Runner.estimate_input_tokens(@game, locales)
                rescue Translation::Client::Error
                  nil
                end
    render :confirm
  end

  def load_game
    @game = Game.find(params[:game_id])
  end

  # With no key the feature does not exist. The views also hide every entry
  # point, but a guard at the controller is what makes that a rule rather than
  # a rendering detail.
  def require_api_key!
    # Its own sentence. This guard fires when ANTHROPIC_API_KEY is absent, not
    # when the actor lacks a role -- require_superadmin! above already
    # answered that -- and telling a superadmin they are not a superadmin
    # sends whoever reads it looking in the wrong place.
    raise Authentication::Unauthorized, t("errors.translation_key_missing") unless
      Translation::Client.configured?
  end

  # Opportunistic, not scheduled. The only moment a stale run actually matters
  # is when someone tries to start a new one, so that is where it is cleared.
  def sweep_stale_runs
    TranslationRun.sweep_stale!
  end

  def refuse(reason, options = {})
    flash[:alert] = t("translations.runs.#{reason}", **options)
    redirect_to edit_game_path(@game)
  end

  # Rails.application.executor.wrap is load-bearing, not ceremony: a bare
  # Thread leaks a connection from the pool and does not participate in code
  # reloading. On a host with ~1.1 GB spare, leaked connections are not
  # theoretical.
  def start(run)
    Thread.new do
      Rails.application.executor.wrap do
        Translation::Runner.new(run).call
      end
    end
  end
end
