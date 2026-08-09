# -*- encoding : utf-8 -*-
#
# Operator-tunable numbers that must be changeable without a deploy.
#
# Defaults live here rather than as seed rows so a fresh database, a restored
# one, and a test transaction all behave identically -- and so deleting a row
# is a safe way back to the shipped value.
class Setting < ApplicationRecord
  DEFAULTS = {
    # Per client IP, per window. 0 disables the limit entirely -- see
    # RequestThrottling, which checks for it before touching the cache.
    "signup_max"            => 5,
    "signup_window_seconds" => 3600,
    "reset_max"             => 3,
    "reset_window_seconds"  => 3600
  }.freeze

  validates :name, :presence => true, :uniqueness => true,
                   :inclusion => { :in => DEFAULTS.keys }
  # greater_than_or_equal_to, not greater_than: zero is the documented "off"
  # switch and an operator will reach for it during an incident.
  validates :value, :numericality => { :only_integer => true,
                                       :greater_than_or_equal_to => 0 }

  def self.integer(name)
    find_by(:name => name)&.value || DEFAULTS.fetch(name)
  end

  def self.put(name, value)
    record = find_or_initialize_by(:name => name)
    record.value = value
    record.save!
    record
  end
end
