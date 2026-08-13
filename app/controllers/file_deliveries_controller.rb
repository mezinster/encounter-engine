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

  # X-Content-Type-Options: nosniff is on every response here -- success or
  # refusal -- but not because of anything in this file. It comes from
  # ActionDispatch::Response.default_headers, applied app-wide before this
  # controller ever runs (confirmed with `bin/rails runner`). A `before_action`
  # setting it here used to exist; it was dead code -- deleting it, and
  # separately deleting only its success-path use, both left all 24 examples
  # in spec/requests/file_deliveries_spec.rb green, because the framework
  # default already covers every branch below. Deleting the header outright
  # (`headers.delete`) is what actually turns two examples red, which is what
  # they pin: the CONTRACT that a MIME-sniffing browser must not second-guess
  # a refusal body any more than a real file, not this controller's
  # (nonexistent) contribution to it. See "sets nosniff on a served file" /
  # "sets nosniff on a refusal too" below.
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
    return head(:not_found) unless GameFileAccess.new(current_user, file, :run => requested_run(file)).permitted?

    deliver(file, params[:variant])
  end

  private

  # Phase 3B: a past-run log/results screen (LogsController#find_run,
  # GamePassingsController#find_run) already resolved which run it is
  # showing from the SAME ?run=N shape, and links its attachments through
  # here carrying it -- so this route authorises against that run's
  # passing, not always game.current_run's. See GameFileAccess's :run
  # parameter and its resolved_run/passing_for_game comments for what
  # happens once it gets there: the team still has to actually HAVE a
  # passing in the named run, so this parameter is never trusted on its
  # own, only used to pick WHICH run gets asked.
  #
  # Scoped to file.game.runs, exactly like LogsController#find_run and
  # GamePassingsController#find_run scope to @game.runs -- a run id from a
  # different game can never reach GameFileAccess through this path.
  #
  # Blank/absent :run and an ordinal that names no run at all both resolve
  # to nil here. GameFileAccess reads nil as "none was named" and falls
  # back to game.current_run -- today's pre-3B behaviour -- so a bogus
  # ordinal can never grant more than omitting :run entirely; it is never
  # treated as "a real run the team has no passing in" (which is refused
  # outright by GameFileAccess, not silently downgraded to "unspecified").
  def requested_run(file)
    return nil if params[:run].blank?

    file.game.runs.find_by(:ordinal => params[:run].to_i)
  end

  def deliver(file, variant)
    attachment = blob_for(file, variant)
    # attachment.nil? alone is NOT enough for "original": file.file (an
    # ActiveStorage::Attached::One) is never nil, purged or not -- #attached?
    # is what actually reflects a purged blob. Without this half, `file.purge`
    # followed by a GET returned 200 with an empty body instead of 404
    # (measured on this branch before this line existed). blob_for's other two
    # branches (existing_web_variant/existing_thumb_variant) already return
    # nil outright when no variant record exists, so attachment.nil? still
    # carries its own weight for those.
    return head(:not_found) if attachment.nil? || !attachment.attached?

    # Variant-scoped, deliberately not checksum-only: a checksum-only ETag is
    # identical for original/web/thumb, so a client holding the 320px
    # thumbnail would be told its copy of the full-size original is fresh,
    # and would go on rendering the thumbnail everywhere it asks for the
    # original. stale? sets the 304 itself (via fresh_when's `head
    # :not_modified`, which renders no body) and returns false when the
    # client's copy is current, so the download below never runs.
    #
    # :cache_control is passed IN to stale? rather than set on response.headers
    # afterward, and that is load-bearing, not style: fresh_when (which stale?
    # calls first, before checking freshness) merges :cache_control into
    # response.cache_control unconditionally, so it lands on the early
    # `head :not_modified` return below exactly as it lands on a 200. Setting
    # response.headers["Cache-Control"] after this line, as a previous version
    # of this method did, only ever executes on the 200 path -- the 304 return
    # happens first -- so a revalidated response fell through to Rails'
    # etag-driven default of "max-age=0, private, must-revalidate" (confirmed
    # on a real 304). That silently defeated the point of max-age=3600: once a
    # client revalidates once, its cached copy's freshness drops to zero and
    # every later view of the play screen makes a conditional request per
    # image -- exactly the round trip max-age exists to avoid on this 1-vCPU
    # host. :public => false keeps the "private" half either way. Both the 200
    # and the 304 carrying "private, max-age=3600" is pinned in
    # spec/requests/file_deliveries_spec.rb ("marks the response private,
    # never public" and "pins max-age on both a 200 and a 304").
    return unless stale?(:etag => [ file.checksum, variant ], :public => false,
                          :cache_control => { :max_age => 3600 })

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
    #
    # #path_for is also not public API -- it's marked `# :nodoc:` on
    # ActiveStorage::Service::DiskService in activestorage 8.0.5.1, so a Rails
    # upgrade could rename or remove it with no deprecation cycle, unlike a
    # documented method. Nothing here can guard against that beyond a normal
    # test run catching the NoMethodError after a Rails bump; noted so it's
    # not a mystery why this line broke, if it ever does.
    #
    # A missing blob is an expected state, not an exception (design §3, I3): the
    # database row can outlive the bytes -- a database restored without its
    # storage volume, an interrupted upload, a purge_orphans run against a
    # stale row, a half-finished azcopy sync. path_for above is a pure string
    # join (confirmed against activestorage 8.0.5.1's DiskService#path_for) --
    # it never touches the filesystem and cannot raise for a missing file.
    # send_file is what actually opens the path, and
    # ActionController::MissingFile is the class it raises when that open
    # fails (confirmed empirically on this branch: File.file?(path) is false
    # for a service-deleted key, and MissingFile is what came out -- NOT
    # ActiveStorage::FileNotFoundError, which only Service#download/
    # #download_chunk raise, and this method never calls either). Rescued
    # narrowly, never StandardError: a blanket rescue here would turn a real
    # storage misconfiguration into a silent 404 on every file at once, which
    # looks exactly like an authorization bug.
    # send_file hands the absolute path to Rack::Sendfile, which is capable of
    # returning an X-Accel-Redirect/X-Sendfile response instead of streaming
    # the bytes itself, IF something tells it to. config.action_dispatch.
    # x_sendfile_header is unset in this app (grep config/ -- nothing sets
    # it), so Rack::Sendfile's own @variation is nil here. What actually keeps
    # a client from choosing that behaviour itself, by sending its own
    # `X-Sendfile-Type: X-Accel-Redirect` request header, is NOT this app's
    # config -- it's rack 3.2.6+: Rack::Sendfile#variation's comment reads
    # "HTTP_X_SENDFILE_TYPE is intentionally NOT read for security reasons"
    # (lib/rack/sendfile.rb). A rack downgrade past that fix would let any
    # client ask for X-Accel-Redirect and receive the absolute storage path
    # back instead of the file's bytes. See the Gemfile's `gem "rack"` floor,
    # added for this reason -- this app has no config-level defence of its
    # own against that regression.
    begin
      send_file attachment.service.path_for(attachment.key),
                :type => file.content_type,
                :filename => file.filename,
                :disposition => disposition_for(file)
    rescue ActionController::MissingFile
      # Never log e.message here: ActionController::MissingFile's message is
      # "Cannot read file #{path}" -- the ABSOLUTE STORAGE PATH -- which does
      # not belong in a production log. Log the identifiers instead: enough
      # to find and investigate the row, nothing that leaks filesystem layout.
      Rails.logger.warn(
        "GameFile blob missing from disk: game_id=#{file.game_id} file_id=#{file.id} " \
        "variant=#{variant} key=#{attachment.key}"
      )

      # stale? above already ran and set Cache-Control to "max-age=3600,
      # private" on THIS response before we ever got here -- it has no idea
      # send_file is about to fail. Left alone, that header ships on a 404
      # for a file that is a design §3 invariant I3 EXPECTED transient state
      # (a database restored without its storage volume, a half-finished
      # azcopy sync): ops restores the volume, and every client that hit the
      # file while it was gone keeps rendering a broken image for up to an
      # hour, making no request the restored server could ever answer.
      # Overwrite it here, on the one path where the byte stream never
      # shipped. expires_now is ActionController::ConditionalGet's own helper
      # for exactly this -- `response.cache_control.replace(:no_cache =>
      # true)` -- so this replaces the whole hash stale? populated (dropping
      # its :max_age/:public) rather than merging into it. The 200 and 304
      # above are untouched -- this rescue clause is the only place that runs
      # on the missing-blob path.
      expires_now
      head :not_found
    end
  end

  # The whitelist of content types actually served inline -- the four values
  # GameFileUpload (the sole writer of GameFile#content_type) ever produces,
  # minus application/pdf. Same shape as GameFile::PERMITTED / the svg
  # exclusion reasoning at app/models/game_file.rb:20-23: a permit-list, not
  # a deny-list, because GameFile only validates content_type's PRESENCE, not
  # its value, so this is the one place standing between an unexpected value
  # reaching this row (a hand-crafted update_column today; a future writer
  # tomorrow) and it being served `inline`. Proven reachable: forcing
  # content_type to "text/html" and requesting the file served it 200 inline
  # text/html before this whitelist existed -- stored XSS, since `nosniff`
  # cannot help when the type genuinely says text/html.
  INLINE_CONTENT_TYPES = %w[image/jpeg image/png image/gif].freeze

  # PDF is always a download, never inline: the browser's PDF viewer is a
  # scripting environment this app does not control, and unlike an image a
  # PDF cannot be re-encoded into inert bytes by the upload pipeline (§2).
  # Every other permitted type (jpg/png/gif, heic canonicalised to jpg) is an
  # image and renders inline -- but the default is `attachment`, not
  # `inline`: anything NOT in INLINE_CONTENT_TYPES (including a PDF, and
  # including any value this method has never seen) downloads instead of
  # rendering. Fails closed, deliberately, in the direction of "content type
  # we don't recognise" rather than "type we didn't explicitly forbid".
  def disposition_for(file)
    INLINE_CONTENT_TYPES.include?(file.content_type) ? "inline" : "attachment"
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
