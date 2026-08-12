# -*- encoding : utf-8 -*-
#
# Operator-tunable numbers that must be changeable without a deploy.
#
# Defaults live here rather than as seed rows so a fresh database, a restored
# one, and a test transaction all behave identically -- and so deleting a row
# is a safe way back to the shipped value.
class Setting < ApplicationRecord
  # Per client IP, per window. 0 disables the limit entirely -- see
  # RequestThrottling, which checks for it before touching the cache.
  RATE_LIMIT_DEFAULTS = {
    "signup_max"            => 5,
    "signup_window_seconds" => 3600,
    "reset_max"             => 3,
    "reset_window_seconds"  => 3600
  }.freeze

  # Game file storage. See
  # docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md §6.
  #
  # Deliberately NOT in DEFAULTS below, which is what the admin settings page
  # iterates: nothing enforces these until phase 2, and a settings screen
  # offering a quota that no code obeys is worse than no screen at all. Phase 2
  # points DEFAULTS at INTEGER_DEFAULTS and adds the five
  # admin.settings.names.* labels across all seven locales in the same change
  # that adds the enforcement.
  STORAGE_DEFAULTS = {
    "file_max_megabytes"         => 25,
    "max_files_per_upload"       => 10,
    "game_quota_megabytes"       => 100,
    "instance_cap_megabytes"     => 4096,
    "free_space_floor_megabytes" => 2048
  }.freeze

  # Every integer key that Setting.integer will answer for and that the
  # numericality validation applies to.
  INTEGER_DEFAULTS = RATE_LIMIT_DEFAULTS.merge(STORAGE_DEFAULTS).freeze

  # List-of-strings keys. Stored space-separated in string_value.
  #
  # allowed_extensions is NOT the last word on what may be uploaded: it is
  # intersected with a hard-coded constant before use, so a superadmin can
  # narrow the set but cannot widen it to something that executes (svg, html).
  # See the design's §4.
  STRING_DEFAULTS = {
    "allowed_extensions" => %w[jpg jpeg png gif heic pdf]
  }.freeze

  # What the admin settings page renders -- unchanged, four keys. See the
  # pre-flight ruling in this task's plan text.
  DEFAULTS = RATE_LIMIT_DEFAULTS

  validates :name, :presence => true, :uniqueness => true,
                   :inclusion => { :in => INTEGER_DEFAULTS.keys + STRING_DEFAULTS.keys }

  # Conditional now, unconditional before: a string key legitimately has a nil
  # `value`. greater_than_or_equal_to, not greater_than -- zero is the
  # documented "off" switch and an operator will reach for it during an
  # incident.
  validates :value, :numericality => { :only_integer => true,
                                       :greater_than_or_equal_to => 0 },
                    :if => :integer_key?

  def self.integer(name)
    find_by(:name => name)&.value || INTEGER_DEFAULTS.fetch(name)
  end

  def self.list(name)
    record = find_by(:name => name)
    # .dup, not the frozen array itself: STRING_DEFAULTS.freeze only froze the
    # hash, not the arrays inside it, so returning the array as-is would hand
    # every caller a reference to the one shipped default -- a caller doing
    # `Setting.list("allowed_extensions") << "svg"` would permanently widen
    # the process-global default for every game, forever, until restart. The
    # design's §4 invariant is that a superadmin may narrow the allowed set
    # but cannot widen it; a mutable shared default is a way to widen it by
    # accident.
    return STRING_DEFAULTS.fetch(name).dup if record.nil? || record.string_value.nil?

    normalise_list(record.string_value)
  end

  def self.put(name, value)
    record = find_or_initialize_by(:name => name)

    if STRING_DEFAULTS.key?(name)
      record.string_value = normalise_list(value).join(" ")
    else
      record.value = value
    end

    record.save!
    record
  end

  # "JPG  pdf\n png" and %w[JPG pdf png] both become %w[jpg pdf png].
  # Split on any whitespace or comma: the admin form is a free-text field and
  # an operator will separate with whichever of the two they think of first.
  def self.normalise_list(value)
    Array(value).join(" ").downcase.split(/[\s,]+/).reject(&:empty?).uniq
  end

  private

  def integer_key?
    INTEGER_DEFAULTS.key?(name)
  end
end
