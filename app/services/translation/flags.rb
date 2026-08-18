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

    # What "written in the game's own language" looks like, per source locale.
    # Used by `identical` only: see #translatable_source?.
    #
    # A locale absent from this map falls back to ANY letter -- the behaviour
    # every locale had before this map existed, except that a source of pure
    # digits ("17") is no longer flagged. That default is the safe direction:
    # available_locales can grow without anyone remembering this file, and a
    # new language must not silently switch a check off.
    SOURCE_SCRIPTS = {
      "ru" => /\p{Cyrillic}/, "uk" => /\p{Cyrillic}/, "be" => /\p{Cyrillic}/,
      "ka" => /\p{Georgian}/,
      "en" => /\p{Latin}/,    "pl" => /\p{Latin}/,    "tr" => /\p{Latin}/
    }.freeze
    ANY_LETTER = /\p{L}/

    # String#strip trims ASCII whitespace ONLY, so a proposal consisting of a
    # single non-breaking space escaped `empty` and compared unequal in
    # `identical` -- and NBSP is exactly the sort of character machine output
    # plausibly contains. [[:space:]] is Unicode-aware on a UTF-8 string and
    # does match U+00A0.
    OUTER_SPACE = /\A[[:space:]]+|[[:space:]]+\z/

    # source_locale is the game's primary_locale -- required, not defaulted:
    # the one production caller has it to hand, and a default here would let a
    # future caller silently fall back to the loosest rule.
    def self.for(source:, proposed:, source_locale:)
      source   = trim(source)
      proposed = trim(proposed)

      flags = []
      flags << "empty"       if proposed.empty?
      flags << "identical"   if !proposed.empty? && proposed == source &&
                                translatable_source?(source, source_locale)
      flags << "lost_digits" if lost?(DIGITS, source, proposed)
      flags << "lost_latin"  if lost?(LATIN,  source, proposed)
      flags << "length"      if implausible_length?(source, proposed)
      flags
    end

    def self.trim(text)
      text.to_s.gsub(OUTER_SPACE, "")
    end

    # Was there anything here for the model to translate?
    #
    # `identical` asks "did the model fail to translate this", and that question
    # only means something when the source held source-language words. A quiz
    # option that is a brand name or a number ("Gucci", "17") comes back
    # unchanged because unchanged is the correct translation, and flagging it
    # buries the one case this check exists for -- source-language text echoed
    # back, which then satisfies the publish gate -- in noise a reviewer has to
    # clear by hand.
    #
    # The test is on the SOURCE STRING, not on the game: a Latin-only field in
    # a Russian game ("Follow the white rabbit", if an author wrote one) is
    # suppressed too, and so is every field of a game authored in a Latin
    # script. "Gucci" and an untranslated English sentence are the same shape
    # here and cannot be told apart. Accepted deliberately: the alternative
    # rules that separate them also silence a one-word source left
    # untranslated, which is a real miss on the case this check exists for.
    def self.translatable_source?(source, source_locale)
      source.match?(SOURCE_SCRIPTS.fetch(source_locale.to_s, ANY_LETTER))
    end

    # Asymmetric on purpose: a token the SOURCE contains and the proposal does
    # not is a dropped code. A token the proposal introduces is just the target
    # language -- "Find the sign" is full of Latin and entirely correct.
    def self.lost?(pattern, source, proposed)
      (source.scan(pattern) - proposed.scan(pattern)).any?
    end

    # Both arguments arrive already trimmed from .for.
    def self.implausible_length?(source, proposed)
      return false if source.length < MIN_LENGTH_FOR_RATIO

      ratio = proposed.length.to_f / source.length
      ratio < SHORT_RATIO || ratio > LONG_RATIO
    end

    private_class_method :lost?, :implausible_length?, :trim, :translatable_source?
  end
end
