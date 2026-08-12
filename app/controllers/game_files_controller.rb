# -*- encoding : utf-8 -*-
#
# The per-game file library, for the game's author and for superadmins.
#
# All ingest work lives in GameFileUpload; this controller authorises, batches
# and renders. That split is deliberate: the upload pipeline is where the
# security model lives (sniffing, canonicalisation, the PERMITTED ceiling, the
# three disk guards) and it must not acquire a second entry point.
class GameFilesController < ApplicationController
  include SecurityFilters

  before_action :find_game
  # ensure_author ALREADY admits superadmins -- see the SECURITY CHOKEPOINT
  # comment in SecurityFilters. That is exactly this page's rule, so there is
  # no second permission check here; a parallel one would drift out of sync.
  before_action :ensure_author
  # Writing is content, so the editing lock applies. Listing is a read-only
  # view and deliberately stays off it, matching the filter's own comment.
  before_action :ensure_editing_not_locked, :only => [ :create, :destroy ]

  # NOTE: ensure_game_was_not_started is deliberately NOT applied. LevelsController
  # uses it and copying that filter list would break this feature: the design
  # specifies a typed confirmation for deleting a file attached to a level in a
  # RUNNING game, which presumes running games are reachable. Authors add and
  # replace photographs mid-quest.

  def index
    @files = GameFile.of_game(@game).order(:filename)
    @used_megabytes = GameFile.storage_used_by(@game) / 1024 / 1024
    @quota_megabytes = Setting.integer("game_quota_megabytes")
    @typed_confirmation_ids =
      @game.status == :running ? @files.select { |f| f.file_attachments.any? }.map(&:id) : []
  end

  def create
    submitted = Array(params[:files]).reject(&:blank?)

    unless GameFileUpload.batch_within_limit?(submitted.size)
      # The app must enforce this, not only kamal-proxy: the proxy answers a
      # bare 413 before Rails runs, so the author would get a browser error page
      # instead of a translated message.
      redirect_to game_game_files_path(@game), :alert => GameFileUpload.batch_limit_message
      return
    end

    rejected = submitted.filter_map do |uploaded|
      # A well-formed <input type=file multiple> submission puts an uploaded-file
      # object at every array slot, but params are attacker-controlled: a
      # hand-built multipart request can put a plain string (or anything else)
      # at files[]. Duck-typing on the interface GameFileUpload actually calls
      # (#tempfile) -- rather than pinning ActionDispatch::Http::UploadedFile --
      # keeps this honest about what breaks it, and treats a malformed entry as
      # an ordinary per-file rejection instead of an unhandled 500 that could
      # leave an earlier, already-committed file in the batch unconfirmed to
      # its author.
      unless uploaded.respond_to?(:tempfile)
        next "#{uploaded}: #{I18n.t("game_files.upload.unsupported_type")}"
      end

      file = GameFileUpload.new(@game, uploaded, current_user).call
      next if file.persisted?

      "#{uploaded.original_filename}: #{file.errors[:file].join(", ")}"
    end

    # Per file, not atomic. An author who picked one oversized photo must not
    # have to re-select the other nine.
    redirect_to game_game_files_path(@game),
                :alert => (rejected.join("; ") if rejected.any?)
  end

  def destroy
    file = GameFile.of_game(@game).find(params[:id])

    if typed_confirmation_required?(file) && params[:confirm_filename] != file.filename
      redirect_to game_game_files_path(@game),
                  :alert => t("game_files.index.type_the_filename", :filename => file.filename)
      return
    end

    file.destroy
    redirect_to game_game_files_path(@game), :notice => t("game_files.index.deleted")
  end

  private

  # Only for a file a live game is actually serving. :running specifically --
  # Game#started? is also true of a finished game, where deleting a photo harms
  # nobody.
  def typed_confirmation_required?(file)
    @game.status == :running && file.file_attachments.any?
  end

  def find_game
    @game = Game.find(params[:game_id])
  end
end
