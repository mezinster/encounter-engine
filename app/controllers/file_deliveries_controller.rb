# -*- encoding : utf-8 -*-
#
# Every attached byte a player receives comes through here. See §4 of
# docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md.
class FileDeliveriesController < ApplicationController
  # The whitelist. A requested variant is matched against this before anything
  # touches storage, and the matched value is used to pick a METHOD, never to
  # build a path -- so no request-supplied string reaches the filesystem.
  #
  # Deliberately redundant with the :variant :constraints regex on this
  # action's route (config/routes.rb): as long as the two lists agree, the
  # route rejects any bad variant before this controller ever runs, so no
  # HTTP request can exercise this line with a value outside the list (proven
  # in spec/requests/file_deliveries_spec.rb -- removing this guard leaves
  # every example passing). It stays anyway as defense against the two lists
  # drifting apart, e.g. if the route's regex is ever loosened without this
  # array changing to match.
  VARIANTS = %w[original web thumb].freeze

  def show
    game = Game.find_by(:id => params[:game_id])
    file = game && GameFile.find_by(:id => params[:id], :game_id => game.id)

    # One refusal for every failure: missing game, missing file, wrong game,
    # unknown variant, not permitted. A distinct status for any of them tells
    # an id-enumerating attacker which guesses were right.
    return head(:not_found) if file.nil?
    return head(:not_found) unless VARIANTS.include?(params[:variant])
    return head(:not_found) unless GameFileAccess.new(current_user, file).permitted?

    deliver(file, params[:variant])
  end

  private

  def deliver(file, variant)
    blob = blob_for(file, variant)
    return head(:not_found) if blob.nil?

    send_data blob.download, :type => file.content_type,
                             :filename => file.filename,
                             :disposition => "inline"
  end

  # Returns nil rather than raising when the variant does not apply to this
  # content type -- web_variant is nil for GIF, thumb_variant is nil for PDF.
  # Task 4 extends this to the case where the BLOB is gone.
  def blob_for(file, variant)
    case variant
    when "original" then file.file
    when "web"      then file.web_variant&.image
    when "thumb"    then file.thumb_variant&.image
    end
  end
end
