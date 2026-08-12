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
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end
end
