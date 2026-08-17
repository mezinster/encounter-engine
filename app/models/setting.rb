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
  # Phase 1 kept these out of DEFAULTS below, which is what the admin settings
  # page iterates: nothing enforced these yet, and a settings screen offering a
  # quota that no code obeys is worse than no screen at all. Phase 2 (this
  # change) is what adds the enforcement, so DEFAULTS now points at
  # INTEGER_DEFAULTS and these join the page, with their five
  # admin.settings.names.* labels across all seven locales.
  STORAGE_DEFAULTS = {
    "file_max_megabytes"         => 25,
    "max_files_per_upload"       => 10,
    "game_quota_megabytes"       => 100,
    "instance_cap_megabytes"     => 4096,
    # 3072, not the 2048 phase 1 shipped. The floor's job changed: with no
    # separate partition available on this host, it is the only thing standing
    # between uploads and the next deploy. Sized from what it protects --
    # roughly two image pulls (561 MB each and growing), a rollback target, and
    # slack for the neighbouring tenants.
    "free_space_floor_megabytes" => 3072
  }.freeze

  # Blast radius for one AI translation run, counted in FIELDS x LOCALES --
  # Runner.plan flattens the work-list across locales, so translating into six
  # languages costs six times the fields.
  #
  # Raised from 400 on 2026-08-17. "A whole game into every registered locale is
  # a few hundred fields", which is what the previous note here said, was simply
  # wrong for a quiz: options are a translatable field each, so a ~70-question
  # game is ~492 fields at ONE language and ~2952 at six. 400 was not a cost
  # ceiling in practice, it was a wall -- that game could not be translated at
  # all.
  #
  # 5000 clears it into every locale with headroom while still refusing
  # something pathological. This is a backstop, not a working limit: the cost
  # guard is the confirmation screen, which prices the run before anything is
  # spent. Raising it was only safe once Runner.estimate_input_tokens stopped
  # costing one API round trip per unit per locale, since this cap was the only
  # thing keeping that pre-flight from ever being reached.
  TRANSLATION_DEFAULTS = {
    "translation_max_fields_per_run" => 5_000
  }.freeze

  # Every integer key that Setting.integer will answer for and that the
  # numericality validation applies to.
  INTEGER_DEFAULTS = RATE_LIMIT_DEFAULTS.merge(STORAGE_DEFAULTS)
                                        .merge(TRANSLATION_DEFAULTS).freeze

  # List-of-strings keys. Stored space-separated in string_value.
  #
  # allowed_extensions is NOT the last word on what may be uploaded: it is
  # intersected with a hard-coded constant before use, so a superadmin can
  # narrow the set but cannot widen it to something that executes (svg, html).
  # See the design's §4.
  STRING_DEFAULTS = {
    "allowed_extensions" => %w[jpg jpeg png gif heic pdf]
  }.freeze

  # Single-valued, chosen from a fixed set. A third category because neither
  # existing one fits: INTEGER_DEFAULTS is numeric, and STRING_DEFAULTS is a
  # LIST normalised by normalise_list and validated by ENTRY, which rejects
  # hyphens and anything over ten characters -- "claude-opus-5" fails that
  # twice over. Stored in string_value alongside the list keys; the two are
  # told apart by which hash the name appears in.
  ENUM_DEFAULTS = {
    "translation_model" => "claude-opus-5"
  }.freeze

  # An allow-list, not free text, for the same reason allowed_extensions is
  # intersected with a constant: a superadmin may choose among costed,
  # supported models but must not be able to introduce one nobody has tested.
  # Exact IDs -- never append a date suffix, which 404s.
  ENUM_ALLOWED = {
    "translation_model" => %w[claude-opus-5 claude-sonnet-5 claude-haiku-4-5].freeze
  }.freeze

  # What the admin settings page renders. Phase 1 deliberately kept this to the
  # four rate limits, because a settings screen offering a quota that no code
  # obeys is worse than no screen at all. Phase 2 adds the enforcement, so the
  # storage keys join it here -- together with their five
  # admin.settings.names.* labels in all seven locales, in this same change.
  DEFAULTS = INTEGER_DEFAULTS

  validates :name, :presence => true, :uniqueness => true,
                   :inclusion => { :in => INTEGER_DEFAULTS.keys +
                                          STRING_DEFAULTS.keys +
                                          ENUM_DEFAULTS.keys }

  validate :enum_value_is_allowed, :if => :enum_key?

  # Conditional now, unconditional before: a string key legitimately has a nil
  # `value`. greater_than_or_equal_to, not greater_than -- zero is the
  # documented "off" switch and an operator will reach for it during an
  # incident.
  validates :value, :numericality => { :only_integer => true,
                                       :greater_than_or_equal_to => 0 },
                    :if => :integer_key?

  # Entries are extensions, not free text. Without this,
  # Setting.put("allowed_extensions", 123) stored "123" and a stray path
  # fragment stored whatever it was given -- harmless only because PERMITTED
  # intersects the result, which is defence we should not have to rely on.
  #
  # The lookahead requires at least one letter: a bare [a-z0-9]{1,10} accepts
  # "123", which is exactly the silently-stringified-integer case this
  # validation exists to catch. No real extension is pure digits -- even ones
  # that start with one, like "3gp", carry a letter too.
  ENTRY = /\A(?=.*[a-z])[a-z0-9]{1,10}\z/
  validate :string_entries_are_well_formed, :if => :string_key?

  def self.integer(name)
    find_by(:name => name)&.value || INTEGER_DEFAULTS.fetch(name)
  end

  def self.enum(name)
    record = find_by(:name => name)
    return ENUM_DEFAULTS.fetch(name) if record.nil? || record.string_value.blank?

    record.string_value
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

    if ENUM_DEFAULTS.key?(name)
      record.string_value = value.to_s.strip
    elsif STRING_DEFAULTS.key?(name)
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

  # One `private`, at the bottom, and every instance method below it. There
  # were two, with the public `def self.*` methods sandwiched between them --
  # which reads as though those are private and is not: `private` has no effect
  # on singleton methods at all.
  private

  def string_entries_are_well_formed
    self.class.normalise_list(string_value).each do |entry|
      next if entry.match?(ENTRY)

      errors.add(:string_value, :invalid)
    end
  end

  def string_key?
    STRING_DEFAULTS.key?(name)
  end

  def integer_key?
    INTEGER_DEFAULTS.key?(name)
  end

  def enum_key?
    ENUM_DEFAULTS.key?(name)
  end

  def enum_value_is_allowed
    return if self.class::ENUM_ALLOWED.fetch(name, []).include?(string_value)

    errors.add(:string_value, :inclusion)
  end
end
