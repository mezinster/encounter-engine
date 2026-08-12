# -*- encoding : utf-8 -*-
#
# Explicit, rather than relying on Active Storage's engine happening to load
# ruby-vips during after_initialize. This class calls Vips directly; the day the
# canonical bytes stop going through Active Storage, an implicit require is a
# NameError at the first upload rather than at boot.
require "vips"
#
# The whole ingest path for one uploaded file, and the ONLY place that sets
# GameFile's four denormalised fields (byte_size, derived_byte_size,
# content_type, checksum). They duplicate what the blob knows, deliberately, so
# quota arithmetic needs no join -- and nothing keeps them in sync, so they get
# exactly one writer. A divergence silently corrupts quota accounting, which is
# a security control here rather than a nicety.
class GameFileUpload
  MIME_TO_EXTENSION = {
    "image/jpeg" => "jpg",
    "image/png"  => "png",
    "image/gif"  => "gif",
    "image/heic" => "heic",
    "image/heif" => "heic",
    "application/pdf" => "pdf"
  }.freeze

  # The ceiling on DECODED pixels, which is a different quantity from the
  # ceiling on bytes and is not implied by it. file_max_megabytes bounds the
  # COMPRESSED input, and the compression ratio is the attacker's to choose: a
  # 654 KB PNG measured on this host decodes to 625 megapixels and costs 2.8 s
  # for the canonical re-encode plus 1.7 s per variant. At 25 MB -- comfortably
  # inside the byte limit -- one file is minutes of CPU, and because
  # config.active_job.queue_adapter is :inline that CPU is burned in the Puma
  # worker holding the request. Signup is open, so "author" means any
  # registered account.
  #
  # 50 megapixels: a 48 Mpx phone sensor is the top of the current mainstream
  # and a full-frame camera sits around 45, so the bound is above anything a
  # real photograph arrives as, while a bomb is typically hundreds of megapixels
  # -- orders of magnitude away, not a near miss.
  MAX_PIXELS = 50_000_000

  # The per-request batch ceiling, enforced by the caller rather than here:
  # this class ingests exactly one file, so the count is only knowable one level
  # up. Phase 2B's controller calls it before constructing any GameFileUpload.
  #
  # It must exist in the app, not only in the proxy. L0's 64 MB
  # max_request_body was computed as file_max x this limit plus slack, so
  # without an app-side check the batch size is bounded only by kamal-proxy --
  # which answers a bare 413 before Rails runs, so the author gets a browser
  # error page instead of a translated message.
  def self.batch_within_limit?(count)
    count.to_i <= Setting.integer("max_files_per_upload")
  end

  # The refusal to show when batch_within_limit? says no. Kept beside the check
  # so the two cannot drift apart.
  def self.batch_limit_message
    I18n.t("game_files.upload.too_many_files",
           :max => Setting.integer("max_files_per_upload"))
  end

  # The filesystem uploads actually land on, which is not Rails.root. In the
  # image the service root is /rails/storage, which config/deploy.yml now mounts
  # as its own named volume and config/storage.yml says should preferably be its
  # own partition. Today the volume sits on the same device so both numbers
  # agree; the day that partition exists, probing Rails.root would measure a
  # filesystem uploads never touch and read healthy forever -- and L4 is no
  # longer defence-in-depth, it is the only thing between uploads and the next
  # deploy.
  #
  # Public and on the class, not private on the instance, for exactly one
  # reason: the admin dashboard renders "Free disk space (MB)" directly beside
  # "Free disk space floor (MB)" -- the floor this guard compares against --
  # and it used to measure Rails.root. Two numbers side by side inviting a
  # comparison, taken from two filesystems. One expression, one caller-visible
  # name, so they cannot drift.
  #
  # try(:root): only the Disk service exposes one. S3, Azure and Mirror do not,
  # and for them the free space of the local disk is still the right thing to
  # watch, since /tmp is on it and every transit stage passes through /tmp.
  #
  # The walk up to an existing ancestor is not defensive padding. The Disk
  # service creates its root lazily, on the first write, and `df` on a path that
  # does not exist prints nothing -- which DiskSpace reads as zero megabytes
  # free, so a brand-new instance would refuse every upload with "the disk is
  # low on space" until someone happened to create the directory. The ancestor
  # is on the same filesystem by definition, so the answer is the same one.
  def self.storage_root
    path = Pathname.new((ActiveStorage::Blob.service.try(:root) || Rails.root).to_s)
    path = path.parent until path.exist? || path.root?
    path.to_s
  end

  def initialize(game, uploaded_file, uploaded_by)
    @game = game
    @uploaded_file = uploaded_file
    @uploaded_by = uploaded_by
  end

  def call
    game_file = GameFile.new(:game => @game, :uploaded_by => @uploaded_by)

    extension = sniffed_extension
    return reject(game_file, :unsupported_type) if extension.nil?
    return reject(game_file, :type_not_allowed) unless allowed?(extension)
    return reject(game_file, :too_large) if too_large?
    return reject(game_file, :too_many_pixels) if too_many_pixels?(extension)
    return reject(game_file, :disk_full) unless room_on_disk?
    return reject(game_file, :instance_full) unless room_in_instance?

    canonical = canonicalise(extension)

    game_file.filename = unique_filename(canonical[:filename])
    game_file.content_type = canonical[:content_type]

    # The quota check is time-of-check/time-of-use: two uploads both read
    # "38 MB used of 100", both conclude they fit, both write, the game lands at
    # 62. The lock is held across check AND write. Overshoot would be survivable
    # only because the free-space floor is a hard backstop -- which is why that
    # floor must never later be dropped as redundant.
    #
    # No `return` inside the block: with_lock opens a transaction, and returning
    # out of a transaction block is a construct Rails has changed the semantics
    # of more than once. Assign and fall through instead.
    result = nil

    @game.with_lock do
      result =
        if room_in_quota?(incoming_size)
          attach_and_measure(game_file, canonical)
        else
          reject(game_file, :quota_full,
                 :left => left_megabytes, :quota => Setting.integer("game_quota_megabytes"))
        end
    end

    # ActiveStorage defers the actual disk write for an attached file to an
    # after_commit callback (Attached::Model), which fires only once the
    # enclosing transaction -- with_lock's, above -- actually completes.
    # Building a variant reads the canonical file back FROM STORAGE, so doing
    # that inside the same lock reads a file that has not been written yet
    # (confirmed: every accepted upload raised ActiveStorage::FileNotFoundError
    # until this was moved out). The number the quota race is about --
    # byte_size, written and checked atomically under the lock -- is
    # unaffected; only the secondary derived_byte_size update happens after
    # the lock releases.
    #
    # By the time this runs, `result` is already a COMMITTED, quota-consuming
    # row -- unlike every other Vips call in this class, which happens before
    # anything is persisted. A failure here cannot be allowed to reach the
    # method-level rescue below: that rescue builds a brand-new, unrelated,
    # unsaved GameFile, which would silently orphan this real row forever
    # (reachable concretely for a GIF: canonicalise never runs GIF bytes
    # through Vips, so thumb_variant's `.processed` call, right here, is the
    # first decode attempt). Handle it locally instead, on the row we actually
    # have: it is not a valid upload if we cannot measure it, so destroy it --
    # has_one_attached's default `dependent: :purge_later` takes the blob with
    # it -- and reject.
    #
    # StandardError, not Vips::Error. Vips is only the likeliest failure, not
    # the only one: ActiveStorage::FileNotFoundError, Errno::ENOSPC from the
    # variant write, an ActiveRecord error on update_column. Any of those
    # escaping leaves a committed row with derived_byte_size = 0 while its
    # variant blobs sit on disk -- a permanent, silent undercount of the quota,
    # with no reconciliation path in this phase.
    if result.persisted?
      begin
        measure_derived!(result)
      rescue StandardError
        result = destroy_and_reject(game_file, :unsupported_type)
      end
    end

    # And now, with the real derived size written, the quota question can be
    # asked properly for the first time -- see room_in_quota? for why the
    # pre-check cannot. This is the same destroy-and-reject path, reached from
    # the other post-commit failure.
    if result.persisted? && !room_in_quota_after_measuring?
      result = destroy_and_reject(game_file, :quota_full) do
        { :left => left_megabytes, :quota => Setting.integer("game_quota_megabytes") }
      end
    end

    result
  rescue Vips::Error
    # A file that sniffs as an image and will not decode is not a valid image,
    # whatever its first bytes say. Only reachable pre-commit: canonicalise is
    # the other Vips call in this method, and it always runs before the lock,
    # so nothing is persisted yet when this fires.
    reject(GameFile.new(:game => @game, :uploaded_by => @uploaded_by), :unsupported_type)
  end

  private

  # Bytes only. Marcel accepts name: and declared_type: hints and PREFERS them,
  # and both are attacker-controlled -- passing the filename would reintroduce
  # exactly what this step exists to ignore.
  def sniffed_extension
    mime = File.open(@uploaded_file.tempfile.path, "rb") { |io| Marcel::MimeType.for(io) }
    MIME_TO_EXTENSION[mime]
  end

  # `extension` here is the MIME-mapped one, and MIME_TO_EXTENSION never
  # produces "jpeg" -- image/jpeg maps to "jpg". So the operator's list is
  # folded onto the same spelling before the comparison. Without that, an
  # operator narrowing allowed_extensions to "jpeg png" blocks every JPEG while
  # the setting reads as if it permits them: a silent, confusing outage from a
  # screen whose whole purpose is to be self-explanatory. PERMITTED is folded
  # too, so the ceiling keeps meaning the same set however it is spelled.
  def allowed?(extension)
    allowed   = Setting.list("allowed_extensions").map { |e| GameFile.normalise_extension(e) }
    permitted = GameFile::PERMITTED.map { |e| GameFile.normalise_extension(e) }

    (allowed & permitted).include?(extension)
  end

  def too_large?
    @uploaded_file.tempfile.size > Setting.integer("file_max_megabytes") * 1024 * 1024
  end

  # libvips is lazy: new_from_file parses the header and decodes nothing, so
  # width and height are known before a single pixel exists. That is what makes
  # a ceiling on decoded size affordable to check -- and it has to be checked
  # here, in front of canonicalise, because canonicalise is the expensive part.
  #
  # PDF is exempt deliberately, and not as an optimisation: vips would answer by
  # invoking its PDF loader, and the design refuses to parse untrusted PDF bytes
  # server-side (§2, "No PDF rasterisation"). PDFs get no variants either, so
  # there is no decode to bound.
  #
  # A header vips cannot read at all is not this check's business: it returns
  # false and lets the format's own path produce the right rejection. Concretely
  # that keeps a corrupt GIF failing where it fails today -- at thumb_variant,
  # after the commit -- instead of being reclassified here.
  def too_many_pixels?(extension)
    return false if extension == "pdf"

    image = Vips::Image.new_from_file(@uploaded_file.tempfile.path, :access => :sequential)
    image.width * image.height > MAX_PIXELS
  rescue Vips::Error
    false
  end

  # Raster images are decoded to pixels and re-encoded with every metadata
  # field dropped. That fixes HEIC, removes EXIF/GPS -- which on a
  # find-this-building puzzle IS the answer -- and is the strongest available
  # anti-polyglot defence: a file that is simultaneously valid JPEG and valid
  # HTML does not survive becoming pixels and being written back out.
  #
  # GIF is validated but NOT re-encoded: re-encoding an animated GIF either
  # loses the animation or needs frame-by-frame handling not worth its risk.
  # PDF cannot be re-encoded without ceasing to be a PDF.
  def canonicalise(extension)
    stem = File.basename(@uploaded_file.original_filename, ".*")
    target = GameFile::CANONICAL_EXTENSION.fetch(extension)

    if %w[gif pdf].include?(extension)
      # binread, not File.open without a block: the handle would be returned
      # inside this hash and never closed, leaking a descriptor per GIF or PDF
      # upload -- and per quota rejection that got this far. The bytes are
      # bounded by file_max_megabytes and the image path already builds a String
      # of the same order.
      return { :io => StringIO.new(File.binread(@uploaded_file.tempfile.path)),
               :filename => "#{stem}.#{target}",
               :content_type => extension == "gif" ? "image/gif" : "application/pdf" }
    end

    image = Vips::Image.new_from_file(@uploaded_file.tempfile.path)
    bytes = case target
            when "jpg" then image.write_to_buffer(".jpg", :strip => true, :Q => 88)
            when "png" then image.write_to_buffer(".png", :strip => true)
            end

    { :io => StringIO.new(bytes),
      :filename => "#{stem}.#{target}",
      :content_type => target == "jpg" ? "image/jpeg" : "image/png" }
  end

  # Unique per game. Suffixes rather than overwriting: a silent overwrite could
  # change a level in a running game.
  def unique_filename(candidate)
    stem = File.basename(candidate, ".*")
    ext  = File.extname(candidate)
    taken = GameFile.of_game(@game).pluck(:filename)

    return candidate unless taken.include?(candidate)

    (2..).each do |n|
      attempt = "#{stem}-#{n}#{ext}"
      return attempt unless taken.include?(attempt)
    end
  end

  def attach_and_measure(game_file, canonical)
    game_file.file.attach(:io => canonical[:io],
                          :filename => game_file.filename,
                          :content_type => canonical[:content_type])

    game_file.byte_size = game_file.file.byte_size
    game_file.checksum  = game_file.file.checksum

    save_with_collision_retry(game_file)
  end

  # Variants are built eagerly, not on first request. With lazy variants a
  # player's page load would trigger a libvips run needing scratch disk, so a
  # full disk would break the PLAY SCREEN mid-race. Eager, it degrades to
  # "authors cannot upload right now" -- design invariant I1.
  #
  # Called after the locking transaction commits, deliberately -- see the
  # comment at the call site in #call.
  #
  # v.blob is NOT the derivative's own blob -- ActiveStorage::VariantWithRecord#blob
  # is an attr_reader holding the SOURCE blob it was built from (see its
  # #initialize), so summing it double-counts the canonical bytes instead of
  # measuring what the variants actually weigh. Confirmed against a real
  # upload: derived_byte_size was landing at exactly 2x the canonical
  # byte_size (11880 for a 5940-byte canonical), while the two variants'
  # real derivative blobs were 6129 and 1404 bytes -- 7533 total, not 11880.
  # v.image.blob is the derivative's own blob (#image reads the
  # ActiveStorage::VariantRecord this variant is tracked as, and returns its
  # attached image) -- that is the number quota accounting means. #record
  # itself is private on VariantWithRecord, so v.record.image.blob would raise
  # NoMethodError; v.image is the public accessor that reaches the same place.
  #
  # Written directly rather than defensively (no `.respond_to?(:image)`
  # fallback to v.blob): file.variant(...) only returns a bare
  # ActiveStorage::Variant, which has no #image and no tracked derivative blob
  # to read, when config.active_storage.track_variants is false. This app runs
  # config.load_defaults 8.0, under which that config defaults to true, and it
  # is not overridden anywhere in config/ -- verified live
  # (ActiveStorage.track_variants #=> true, and file.variant(...) returns
  # VariantWithRecord). A silent fallback to the wrong number if that ever
  # changed would be worse than a loud NoMethodError pointing straight at this
  # comment.
  def measure_derived!(game_file)
    derived = [ game_file.web_variant, game_file.thumb_variant ].compact
    game_file.update_column(:derived_byte_size, derived.sum { |v| v.image.blob.byte_size })
  end

  # The model's uniqueness validation is time-of-check/time-of-use racy against
  # its own unique index: a concurrent upload of the same name passes validation
  # and loses at the insert. Unrescued that is a 500 for a name collision.
  #
  # `requires_new: true` is load-bearing, and SQLite cannot demonstrate why.
  # This runs inside @game.with_lock, i.e. inside an open transaction. A bare
  # save! opens a nested transaction with requires_new: false, which is not a
  # savepoint -- it simply joins the outer one. On PostgreSQL a unique violation
  # puts that whole transaction into the aborted state, so the retry's INSERT
  # does not collide, it raises PG::InFailedSqlTransaction, and the one branch
  # that exists solely to survive a race is the branch that cannot run. SQLite
  # has no aborted-transaction state, so dev and test are green either way:
  # the failure is production-only by construction, and the savepoint is what
  # gives the retry a statement to roll back to.
  def save_with_collision_retry(game_file)
    attempts = 0
    begin
      GameFile.transaction(:requires_new => true) { game_file.save! }
      game_file
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      # "Retry once, then 422" -- the design's §2. A second collision is a
      # rejection carrying a real message, not an exception escaping #call as a
      # 500 for what is, after all, only a duplicate name.
      return reject(game_file, :name_conflict) if attempts > 1

      game_file.filename = unique_filename(game_file.filename)
      retry
    end
  end

  def reject(game_file, key, interpolations = {})
    game_file.errors.add(:file, I18n.t("game_files.upload.#{key}", **interpolations))
    game_file
  end

  # Undo a row that is already committed and already counted against the quota.
  # destroy takes the blob and its variants with it via has_one_attached's
  # default `dependent: :purge_later`, which under the :inline queue adapter is
  # immediate. The interpolations come from a block so they are computed AFTER
  # the destroy -- «осталось N МБ» must report the space the author now has, not
  # the space they had while the doomed row still occupied some of it.
  def destroy_and_reject(game_file, key)
    game_file.destroy
    reject(game_file, key, block_given? ? yield : {})
  end

  def incoming_size
    @uploaded_file.tempfile.size
  end

  # Remaining allowance, floored at zero so a rejection message never reads a
  # negative number.
  def left_megabytes
    quota = Setting.integer("game_quota_megabytes") * 1024 * 1024
    [ quota - GameFile.storage_used_by(@game), 0 ].max / 1024 / 1024
  end

  # Compares against the UPLOADED size, which is the only size available before
  # canonicalisation has written anything -- and it is not the size that will be
  # stored. It ignores the derived bytes entirely, and those are ALWAYS
  # additional: what lands is byte_size + web + thumb. For a small image
  # resize_to_limit [1600, 1600] does not resize at all, so the web variant is
  # roughly the canonical size a second time and the true total can be about
  # twice the number checked here. This check therefore under-counts, which is
  # the unsafe direction, and is a pre-flight rather than the decision.
  #
  # The decision is room_in_quota_after_measuring?, below.
  def room_in_quota?(size)
    used = GameFile.storage_used_by(@game)
    used + size <= Setting.integer("game_quota_megabytes") * 1024 * 1024
  end

  # The same question with nothing left to estimate. By the time this runs the
  # row is committed and measure_derived! has written the real derived size, so
  # storage_used_by already includes every byte this upload occupies -- hence
  # zero incoming bytes.
  def room_in_quota_after_measuring?
    room_in_quota?(0)
  end

  def room_in_instance?
    GameFile.storage_used_everywhere + incoming_size <=
      Setting.integer("instance_cap_megabytes") * 1024 * 1024
  end

  def room_on_disk?
    DiskSpace.available_megabytes(storage_root) >
      Setting.integer("free_space_floor_megabytes")
  end

  # See the class method of the same name for why this path is not Rails.root
  # and why it is reachable from outside this class.
  def storage_root
    self.class.storage_root
  end
end
