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
  before_action :sweep_stale_runs
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

    run = begin
            TranslationRun.create!(
              :game => @game, :actor => current_user,
              # Frozen here, deliberately: reading the Setting live would let a
              # change mid-run produce proposals from two models with no way
              # to tell which.
              :model => Setting.enum("translation_model"),
              :state => TranslationRun::PENDING,
              :target_locale_list => locales,
              :fields_total => work.size
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
    run.update!(:state => TranslationRun::CANCELLED, :finished_at => Time.now)

    record_admin_action("translation_run_cancelled", @game, "run=#{run.id}")
    redirect_to game_translation_run_path(@game, run)
  end

  private

  def load_game
    @game = Game.find(params[:game_id])
  end

  # With no key the feature does not exist. The views also hide every entry
  # point, but a guard at the controller is what makes that a rule rather than
  # a rendering detail.
  def require_api_key!
    raise Authentication::Unauthorized, t("errors.must_be_superadmin") unless
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
