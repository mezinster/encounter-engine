# app/services/translation/flags.rb
#
# Structural checks a reviewer who does not read the target language can still
# act on.
#
# This is the safety story for the whole feature. A superadmin reviewing Polish
# cannot evaluate Polish wording; what they CAN act on is a proposal that is
# empty, that echoes its input, that dropped a code, or whose length is
# implausible. None of these five needs the reviewer to know the language.
module Translation
  module Flags
    # Below this, length ratios are noise: "Да" -> "Yes" is a 150% expansion
    # and perfectly correct.
    MIN_LENGTH_FOR_RATIO = 20

    SHORT_RATIO = 0.4
    LONG_RATIO  = 2.5

    DIGITS = /\d+/
    # Two or more Latin letters, so a stray initial does not trip the check.
    LATIN  = /[A-Za-z]{2,}/

    def self.for(source:, proposed:)
      source   = source.to_s
      proposed = proposed.to_s

      flags = []
      flags << "empty"       if proposed.strip.empty?
      flags << "identical"   if !proposed.strip.empty? && proposed.strip == source.strip
      flags << "lost_digits" if lost?(DIGITS, source, proposed)
      flags << "lost_latin"  if lost?(LATIN,  source, proposed)
      flags << "length"      if implausible_length?(source, proposed)
      flags
    end

    # Asymmetric on purpose: a token the SOURCE contains and the proposal does
    # not is a dropped code. A token the proposal introduces is just the target
    # language -- "Find the sign" is full of Latin and entirely correct.
    def self.lost?(pattern, source, proposed)
      (source.scan(pattern) - proposed.scan(pattern)).any?
    end

    def self.implausible_length?(source, proposed)
      return false if source.strip.length < MIN_LENGTH_FOR_RATIO

      ratio = proposed.strip.length.to_f / source.strip.length
      ratio < SHORT_RATIO || ratio > LONG_RATIO
    end

    private_class_method :lost?, :implausible_length?
  end
end
