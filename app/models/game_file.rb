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
end
