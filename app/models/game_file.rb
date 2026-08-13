# -*- encoding : utf-8 -*-
#
# One file in one game's library.
#
# The library is per GAME, not per game-run: levels and hints hang off Game,
# and a GameRun is "one event over that content", so run-scoped files would
# make photographs the only per-run content in the system.
class GameFile < ApplicationRecord
  # optional: true plus an explicit presence validation -- the established
  # shape in this codebase (see Game#author, GameRun#game).
  belongs_to :game, :optional => true
  belongs_to :uploaded_by, :class_name => "User", :optional => true

  # The ceiling on what may ever be uploaded, regardless of what a superadmin
  # puts in the allowed_extensions setting. Read as
  # `Setting.list("allowed_extensions") & GameFile::PERMITTED`.
  #
  # svg is absent on purpose and must stay absent: it is an image format that
  # executes JavaScript, so an <svg onload=...> served inline is stored XSS
  # against every playing team. html, xml and svgz are excluded for the same
  # reason. "Superadmin-manageable" is an operator convenience, not a trust
  # boundary -- a settings screen that can introduce a code-execution vector is
  # a privilege-escalation path wearing a config option's clothes.
  PERMITTED = %w[jpg jpeg png gif heic pdf].freeze

  # Extension → the canonical form it is stored as. HEIC becomes JPEG because
  # no browser but Safari can display HEIC.
  CANONICAL_EXTENSION = {
    "jpg" => "jpg", "jpeg" => "jpg", "heic" => "jpg",
    "png" => "png", "gif" => "gif", "pdf" => "pdf"
  }.freeze

  # Two spellings of one format, folded onto the spelling the pipeline actually
  # uses. This is NOT CANONICAL_EXTENSION, which also folds heic onto jpg --
  # that is a conversion, and an operator who allows heic but not jpg means
  # something by it. jpeg and jpg mean nothing different to anyone.
  EXTENSION_ALIASES = { "jpeg" => "jpg" }.freeze

  def self.normalise_extension(extension)
    EXTENSION_ALIASES.fetch(extension, extension)
  end

  has_many :file_attachments, :dependent => :destroy

  # The canonical bytes. Variants are generated eagerly at upload rather than
  # on first request, so that reading never allocates disk -- see the design's
  # invariant I1.
  has_one_attached :file

  validates :game, :presence => true
  validates :filename, :presence => true,
                       :uniqueness => { :scope => :game_id }
  validates :content_type, :presence => true

  scope :of_game, ->(game) { where(:game_id => game) }

  # What this file actually occupies: the canonical bytes AND the variants
  # derived from them. Quota arithmetic must use this, never byte_size alone.
  def total_byte_size
    byte_size.to_i + derived_byte_size.to_i
  end

  # Bytes used by one game's whole library. Returns 0, never nil, for a game
  # with no files -- callers compare it against a quota.
  def self.storage_used_by(game)
    of_game(game).sum(:byte_size) + of_game(game).sum(:derived_byte_size)
  end

  # Bytes used across every game. Per-game quotas bound nothing on their own --
  # twenty games at a 100 MB quota is 2 GB whether or not the disk has it.
  def self.storage_used_everywhere
    sum(:byte_size) + sum(:derived_byte_size)
  end

  def web_variant
    return nil unless content_type.in?(%w[image/jpeg image/png])

    file.variant(:resize_to_limit => [ 1600, 1600 ]).processed
  end

  def thumb_variant
    return nil if content_type == "application/pdf"

    file.variant(:resize_to_limit => [ 320, 320 ]).processed
  end

  # Read-only counterparts to web_variant/thumb_variant, for the delivery path
  # (FileDeliveriesController) -- design invariant I1: serving an existing
  # file and its variants must be a pure read, never something that allocates
  # disk. The two methods above call `.processed`, which GENERATES the
  # variant when it is absent; that is correct for the two callers that need
  # it (GameFileUpload builds variants eagerly at upload, and
  # lib/tasks/game_files.rake's regenerate_variants exists to (re)generate
  # them) and wrong for a GET, which must 404 instead of running libvips and
  # writing to disk.
  #
  # `.image`, called on the variant transform WITHOUT `.processed`, is the
  # read-only half of the same object. ActiveStorage::VariantWithRecord#image
  # is `record&.image`, and #record (private) only ever READS --
  # `blob.variant_records.find_by(variation_digest: variation.digest)` --
  # never `create_or_find_by!`. Only `#processed` calls `#process`, which is
  # what creates the row. So `.variant(transformations).image` resolves an
  # EXISTING ActiveStorage::VariantRecord if one exists and returns nil
  # otherwise, without ever writing anything -- confirmed empirically: wiping
  # a file's variant_records and calling `.variant(...).image` left the count
  # at 0 and returned nil, while `.variant(...).processed` recreated a row.
  #
  # The transformation hashes are intentionally duplicated from web_variant/
  # thumb_variant above rather than extracted into a shared constant, so as
  # not to touch those two methods at all -- see the class-level warning
  # against changing them. Keep the two pairs of hashes in sync by hand if
  # either transformation ever changes.
  def existing_web_variant
    return nil unless content_type.in?(%w[image/jpeg image/png])

    file.variant(:resize_to_limit => [ 1600, 1600 ]).image
  end

  def existing_thumb_variant
    return nil if content_type == "application/pdf"

    file.variant(:resize_to_limit => [ 320, 320 ]).image
  end
end
