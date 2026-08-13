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
    # Checked first, before either DB lookup below: it costs nothing, and it
    # means a junk variant name never spends a query if the route's own
    # :constraints regex (config/routes.rb) is ever loosened. As long as the
    # route lists the same three values, this line cannot currently be
    # exercised over HTTP -- see the comment on VARIANTS above and
    # spec/requests/file_deliveries_spec.rb's drift-detection example.
    return head(:not_found) unless VARIANTS.include?(params[:variant])

    # One query, not two: GameFile.game_id already scopes to the game, and a
    # GameFile's game_id can only ever reference a real, persisted game --
    # so a :game_id that names no game resolves to no row here exactly as it
    # would have resolved to no Game with a separate lookup first.
    file = GameFile.find_by(:id => params[:id], :game_id => params[:game_id])

    # One refusal for every remaining failure: missing file, wrong game, not
    # permitted. A distinct status for any of them tells an id-enumerating
    # attacker which guesses were right.
    return head(:not_found) if file.nil?
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
  # content type -- existing_web_variant is nil for GIF, existing_thumb_variant
  # is nil for PDF. Task 4 extends this to the case where the BLOB is gone.
  #
  # Deliberately GameFile#existing_web_variant / #existing_thumb_variant here,
  # NOT #web_variant / #thumb_variant. The latter two call `.processed`, which
  # GENERATES the variant (runs libvips, writes to disk) when it is absent --
  # fine for GameFileUpload's eager build at upload time and for the
  # regenerate_variants rake task, wrong on a GET. Design §3 invariant I1: a
  # read must never allocate disk. The existing_* accessors resolve the
  # ActiveStorage::VariantRecord if one exists and return nil otherwise, never
  # creating one -- see the comment on GameFile#existing_web_variant. A missing
  # variant record 404s here exactly like a missing blob does.
  def blob_for(file, variant)
    case variant
    when "original" then file.file
    when "web"      then file.existing_web_variant
    when "thumb"    then file.existing_thumb_variant
    end
  end
end
