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

  def web_variant
    return nil unless content_type.in?(%w[image/jpeg image/png])

    file.variant(:resize_to_limit => [ 1600, 1600 ]).processed
  end

  def thumb_variant
    return nil if content_type == "application/pdf"

    file.variant(:resize_to_limit => [ 320, 320 ]).processed
  end
end
