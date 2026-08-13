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

  # Runs before every action, so it also covers every head(:not_found)
  # refusal in #show below, not just a successful #deliver -- a MIME-sniffing
  # browser must not second-guess a refusal body any more than a real file.
  # Proven in spec/requests/file_deliveries_spec.rb: nosniff is asserted on
  # both a served file and on a plain 404.
  before_action :set_nosniff_header

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

  def set_nosniff_header
    response.headers["X-Content-Type-Options"] = "nosniff"
  end

  def deliver(file, variant)
    attachment = blob_for(file, variant)
    return head(:not_found) if attachment.nil?

    # Variant-scoped, deliberately not checksum-only: a checksum-only ETag is
    # identical for original/web/thumb, so a client holding the 320px
    # thumbnail would be told its copy of the full-size original is fresh,
    # and would go on rendering the thumbnail everywhere it asks for the
    # original. stale? sets the 304 itself (via fresh_when's `head
    # :not_modified`, which renders no body) and returns false when the
    # client's copy is current, so the download below never runs.
    return unless stale?(:etag => [ file.checksum, variant ], :public => false)

    # AFTER stale?, deliberately: stale?/fresh_when write Cache-Control from
    # their :public argument (false above -> "private"), so setting this
    # header any earlier would get silently overwritten. Verified against a
    # real response rather than trusted from this ordering alone --
    # send_data used to touch Cache-Control too; see
    # spec/requests/file_deliveries_spec.rb's "marks the response private"
    # example, which pins the header on the response Rails actually sends,
    # not on this line's position.
    response.headers["Cache-Control"] = "private, max-age=3600"

    # Streams straight off disk instead of loading the whole blob into the
    # Ruby heap the way `send_data blob.download` (Task 1's original shape)
    # did. With file_max_megabytes at 25 and this host at 1 vCPU, several
    # players fetching a large original at once would each hold their own
    # 25 MB copy in the Ruby heap for as long as the slowest connection took
    # -- the ETag above turns *repeat* views into 304s but does nothing for
    # the first fetch per client. See the owner's ruling recorded in
    # .superpowers/sdd/2026-08-13-attachments-phase-3a/task-3-brief.md.
    #
    # attachment.service.path_for(attachment.key) is the Disk-service
    # coupling: it only resolves to a real filesystem path because
    # config/storage.yml's production entry is `service: Disk` (see that
    # file's header comment and the design's "Why not Azure Blob" section for
    # why that is not expected to change soon). A future move to a remote
    # storage service loses the concept of a local path entirely -- this is
    # the line to find and replace with a streaming download at that point,
    # not a mystery to rediscover.
    send_file attachment.service.path_for(attachment.key),
              :type => file.content_type,
              :filename => file.filename,
              :disposition => disposition_for(file)
  end

  # PDF is always a download, never inline: the browser's PDF viewer is a
  # scripting environment this app does not control, and unlike an image a
  # PDF cannot be re-encoded into inert bytes by the upload pipeline (§2).
  # Every other permitted type (jpg/png/gif, heic canonicalised to jpg) is an
  # image and renders inline.
  def disposition_for(file)
    file.content_type == "application/pdf" ? "attachment" : "inline"
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
