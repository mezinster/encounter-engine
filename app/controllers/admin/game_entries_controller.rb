# The operator's admission screen. Opening a run is a superadmin power, but
# populating it was not: GameEntriesController#accept is behind ensure_author,
# which DOES admit superadmins, while games/show.html.erb:47 gates the entries
# block on author_of?, which does NOT -- so the action was permitted and the
# button never rendered. The only routes were borrowing authorship or the
# database.
class Admin::GameEntriesController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!
  before_action :find_game
  before_action :find_entry, only: [ :accept, :reject ]
  # accept only, matching GameEntriesController: rejecting is a release, and
  # it is the only way to clear a stale row -- and give its reserved place
  # back -- on a game that was flipped to pass_required under live entries.
  before_action :ensure_game_is_not_gated, only: :accept

  def index
    @run = @game.current_run
    @pending  = GameEntry.of_run(@run).with_status("new").includes(:team)
    @accepted = GameEntry.of_run(@run).with_status("accepted").includes(:team)
  end

  def accept
    if @entry.status == "new"
      @entry.accept!
      record_admin_action("accept_entry", @game, @entry.team&.name)
    end

    redirect_to admin_game_entries_path(@game),
                :notice => t("admin.entries.accepted_notice", :team => @entry.team&.name)
  end

  # The `status == "new"` guard is load-bearing and copied verbatim from
  # GameEntriesController#reject, not simplified. Its comment there records the
  # failure: free_place_of_team! firing unconditionally lets a double-clicked
  # reject free a place that is not this entry's to free, and the counter then
  # drifts below what is actually taken, letting one extra team past
  # max_team_number. Seen in production with a captain double-clicking
  # «Отозвать».
  def reject
    if @entry.status == "new"
      @entry.reject!
      @game.free_place_of_team!
      record_admin_action("reject_entry", @game, @entry.team&.name)
    end

    redirect_to admin_game_entries_path(@game),
                :notice => t("admin.entries.rejected_notice", :team => @entry.team&.name)
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end

  # Looked up THROUGH the current run rather than by bare id: an entry
  # belonging to another game, or to an earlier run of this one, raises
  # RecordNotFound instead of being acted on. Same discipline as
  # Admin::TeamsController#set_captain finding its member through the team.
  def find_entry
    @entry = GameEntry.of_run(@game.current_run).find(params[:id])
  end

  # A commercial game admits teams through AccessPass alone, so accepting an
  # entry on one grants nothing at all -- /play resolves a gated game through
  # #gated_passing and never consults GameEntry. See
  # GameEntriesController#ensure_game_is_not_gated for the whole story; this
  # is the same refusal at the operator's door, which is a separate controller
  # only because accept's button never rendered for a superadmin.
  def ensure_game_is_not_gated
    raise Authentication::Unauthorized, t("errors.game_is_gated") if @game&.pass_required?
  end
end
