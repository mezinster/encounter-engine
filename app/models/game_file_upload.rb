# -*- encoding : utf-8 -*-
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
    measure_derived!(result) if result.persisted?

    result
  rescue Vips::Error
    # A file that sniffs as an image and will not decode is not a valid image,
    # whatever its first bytes say.
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

  def allowed?(extension)
    (Setting.list("allowed_extensions") & GameFile::PERMITTED).include?(extension)
  end

  def too_large?
    @uploaded_file.tempfile.size > Setting.integer("file_max_megabytes") * 1024 * 1024
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
      return { :io => File.open(@uploaded_file.tempfile.path, "rb"),
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

    game_file
  end

  # Variants are built eagerly, not on first request. With lazy variants a
  # player's page load would trigger a libvips run needing scratch disk, so a
  # full disk would break the PLAY SCREEN mid-race. Eager, it degrades to
  # "authors cannot upload right now" -- design invariant I1.
  #
  # Called after the locking transaction commits, deliberately -- see the
  # comment at the call site in #call.
  def measure_derived!(game_file)
    derived = [ game_file.web_variant, game_file.thumb_variant ].compact
    game_file.update_column(:derived_byte_size, derived.sum { |v| v.blob.byte_size })
  end

  # The model's uniqueness validation is time-of-check/time-of-use racy against
  # its own unique index: a concurrent upload of the same name passes validation
  # and loses at the insert. Unrescued that is a 500 for a name collision.
  def save_with_collision_retry(game_file)
    attempts = 0
    begin
      game_file.save!
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      raise if attempts > 1

      game_file.filename = unique_filename(game_file.filename)
      retry
    end
  end

  def reject(game_file, key, interpolations = {})
    game_file.errors.add(:file, I18n.t("game_files.upload.#{key}", **interpolations))
    game_file
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

  # Compares against the UPLOADED size, which over-counts for a HEIC that will
  # shrink. Deliberate: this check must happen before canonicalisation writes
  # anything, so it uses the only size it has, and erring high is the safe
  # direction.
  def room_in_quota?(size)
    used = GameFile.storage_used_by(@game)
    used + size <= Setting.integer("game_quota_megabytes") * 1024 * 1024
  end

  def room_in_instance?
    GameFile.storage_used_everywhere + incoming_size <=
      Setting.integer("instance_cap_megabytes") * 1024 * 1024
  end

  def room_on_disk?
    DiskSpace.available_megabytes(Rails.root.to_s) >
      Setting.integer("free_space_floor_megabytes")
  end
end
