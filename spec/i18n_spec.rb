# spec/i18n_spec.rb
require "rails_helper"

def leaf_pairs(hash, prefix = "")
  hash.flat_map do |key, value|
    path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
    value.is_a?(Hash) ? leaf_pairs(value, path) : [[path, value]]
  end
end

def locale_data(locale)
  yaml = YAML.load_file(Rails.root.join("config/locales/#{locale}.yml"))
  leaf_pairs(yaml.fetch(locale.to_s)).to_h
end

RSpec.describe "internationalization" do
  ru = locale_data(:ru)
  en = locale_data(:en)

  it "has the same keys in ru and en" do
    # ru and en are the platform's two complete, actively-maintained
    # locales -- every screen is expected to say something in both. This
    # guard has caught real key drift repeatedly (a key added to one file
    # and not the other) and must stay strict for this pair. uk and ka are
    # deliberately NOT held to this standard -- see below.
    expect(en.keys.sort).to eq(ru.keys.sort)
  end

  # uk and ka were registered (config/application.rb) ahead of being
  # translated -- task 12's explicit "register them now, translate later"
  # -- so most of their keys don't exist yet and resolve through
  # config.i18n.fallbacks to the Russian copy instead (proved below). That
  # makes them legitimately PARTIAL locale files, which the strict ru/en
  # parity check above would wrongly reject. What must still hold, even for
  # a partial file, is that every key it DOES define is a real key: a
  # subset of ru's keys, never a superset (an orphan nobody reads) or a
  # sideways set (a typo'd path that silently never resolves). Subset-only,
  # not exact-match, is the whole relaxation.
  #
  # tr, be and pl joined the same group on 2026-08-09 and are partial BY PLAN,
  # not by neglect: they carry the locales.* endonyms only, and
  # docs/superpowers/plans/2026-08-09-locale-translation-delivery.md fills each
  # one in its own PR. config.i18n.fallbacks ([:ru]) is what makes shipping a
  # locale in that state safe -- see the fallback proof below.
  %i[uk ka tr be pl].each do |locale|
    it "only defines keys that also exist in ru (#{locale}.yml may be an incomplete subset)" do
      data = locale_data(locale)
      expect(data.keys - ru.keys).to eq([])
    end
  end

  # The locales.* block is the ONE part of a locale file that fallbacks do not
  # cover, and getting this wrong is not subtle: registering :tr in
  # config/application.rb without adding locales.tr took 224 examples red at
  # once. The reason is worth stating, because "fallbacks make partial locale
  # files safe" is true everywhere else in this suite:
  #
  #   * config.i18n.fallbacks sends a key missing from tr.yml to ru.yml.
  #   * But locales.tr is missing from ru.yml TOO -- it is a new key, not a
  #     new translation -- so there is nothing to fall back to, and the test
  #     environment's raise_on_missing_translations turns that into a raise.
  #   * Several views render t("locales.#{l}") for EVERY available locale:
  #     layouts/_header.html.erb, users/edit.html.erb, games/new.html.erb,
  #     games/edit.html.erb, shared/_language_tabs.html.erb. So the blast
  #     radius is every page with a header, not one screen.
  #
  # There is a second reason beyond not-raising: a switcher exists to be read
  # by someone who cannot read the language currently on screen. A Russian
  # label rendered through fallback would defeat the control even if it did
  # not raise.
  it "names every available locale in every locale file" do
    I18n.available_locales.each do |file_locale|
      data = locale_data(file_locale)

      I18n.available_locales.each do |named|
        expect(data).to have_key("locales.#{named}"),
          "#{file_locale}.yml is missing locales.#{named}"
      end
    end
  end

  it "falls back to Russian for a missing English key" do
    I18n.with_locale(:en) do
      expect(I18n.t("game.not_started")).to be_present
    end
  end

  # This is the proof that a key missing from a registered locale doesn't
  # raise or render blank, it silently reads the Russian copy -- which is what
  # made "register now, translate later" viable at all, and what still covers
  # any future key added to ru.yml before the other files catch up.
  #
  # It used to point at game.not_started, on the strength of uk.yml and ka.yml
  # not defining it (or almost anything else). Both files are now fully
  # translated -- 295 of 295 keys, same as en -- so no real missing key is
  # left to point at, and asserting that a translated locale still returns the
  # Russian copy would assert the exact opposite of what we want. The
  # mechanism under test is unchanged; the probe key is now defined only in
  # :ru, at test time, so the assertion stays honest no matter how complete
  # the locale files get. The subset-not-equality rule above is deliberately
  # left as-is: uk and ka are simply no longer exercising the relaxation.
  %i[uk ka tr be pl].each do |locale|
    it "falls back to the exact Russian copy for a missing #{locale} key" do
      I18n.backend.store_translations(:ru, "spec_fallback_probe" => "Откат к русскому")

      I18n.with_locale(locale) do
        expect(I18n.t("spec_fallback_probe")).to eq("Откат к русскому")
      end
    end
  end

  # Key parity is not meaning parity. Earlier in this migration ru.yml and
  # en.yml both defined the same key while saying materially different
  # things (ru named a specific host, en was generic) -- and a parity check
  # like the one above, which only compares key SETS, is blind to that: both
  # sides had *a* value, just not the same one. This doesn't try to detect
  # that in general -- telling "different wording, same meaning" from
  # "different wording, different meaning" needs a human reader, not a
  # spec. It catches one cheap, narrow proxy instead: an en value that is
  # byte-identical to its ru value almost always means the string was
  # copy-pasted across during translation and never actually translated.
  #
  # A handful of pairs are identical on purpose and are not bugs: a
  # borrowed term ("Email"), a date format, or an endonym in the
  # `locales.*` block (locales.en is meant to read "English" no matter
  # which locale is currently rendering the switcher). Those are named
  # explicitly below rather than exempted by a blanket rule like "identical
  # single words are fine" -- so a *new* identical pair still fails the
  # spec and has to be looked at, not silently waved through.
  it "does not have en values that are an untranslated copy of their ru value" do
    known_legitimate_duplicates = %w[
      users.new.email_label
      users.index.email_label
      time.formats.short
      sessions.new.email_label
      password_resets.new.email
      messengers.telegram
      messengers.whatsapp
      messengers.viber
      messengers.signal
      messengers.max
      users.edit.instagram_label
      users.edit.telegram_label
      users.index.instagram_label
      users.index.telegram_label
      admin.users.show.instagram
      admin.users.show.telegram
      locales.ru
      locales.en
      locales.uk
      locales.ka
      locales.tr
      locales.be
      locales.pl
    ]

    shared_keys = en.keys & ru.keys
    suspicious_keys = shared_keys.select do |key|
      value = en[key].to_s
      !value.strip.empty? && value == ru[key].to_s
    end

    expect(suspicious_keys - known_legitimate_duplicates).to eq([])
  end

  # Key parity (checked above) says nothing about interpolation-variable
  # parity. A value carrying a %{placeholder} its caller never passes raises
  # I18n::MissingInterpolationArgument -- a 500 that only shows up in
  # whichever locale has the mismatched placeholder. Driven off
  # I18n.available_locales rather than a hardcoded list, so registering a
  # locale enrols it here automatically; several of them are partial (see
  # above), so this only compares keys where more than one locale actually
  # defines a value.
  #
  # This is the single most valuable check for machine-produced text: a
  # translator who drops %{nickname} or invents %{user} reddens the build
  # instead of shipping a raise into a live game.
  it "uses the same interpolation variables for a key across every locale that defines it" do
    interpolation_vars = ->(value) { value.to_s.scan(/%\{(\w+)\}/).flatten.sort.uniq }

    locales = I18n.available_locales.to_h { |locale| [locale, locale_data(locale)] }
    all_keys = locales.values.flat_map(&:keys).uniq

    mismatches = all_keys.filter_map do |key|
      present_in = locales.select { |_, data| data.key?(key) }
      next if present_in.size < 2

      vars_by_locale = present_in.transform_values { |data| interpolation_vars.call(data[key]) }
      next if vars_by_locale.values.uniq.size <= 1

      [key, vars_by_locale]
    end

    expect(mismatches).to eq([])
  end

  # Every other guard in this file runs against the PARSED hash, and a
  # duplicate YAML key is already gone by then: YAML resolves duplicates by
  # letting the last one win, so the earlier block is discarded at parse
  # time, silently. Nothing above can see that, and because a duplicate is
  # typically introduced identically in all four files, even the parity and
  # subset checks stay green.
  #
  # This bit us for real: a `team:` block added under
  # activerecord.errors.models in all four locales was swallowed whole by
  # the pre-existing `team:` block further down the same mapping. The keys
  # were in the files, absent from I18n, and the leaf count did not move --
  # which is the only reason anyone noticed.
  #
  # Checked against the Psych node tree rather than the loaded hash,
  # because that is the only representation in which the duplicate still
  # exists.
  it "defines no key twice within the same mapping" do
    duplicates_in = lambda do |node, trail, found|
      case node
      when Psych::Nodes::Mapping
        seen = {}
        node.children.each_slice(2) do |key_node, value_node|
          key = key_node.respond_to?(:value) ? key_node.value : key_node.to_s
          path = (trail + [key]).join(".")
          found << path if seen.key?(key)
          seen[key] = true
          duplicates_in.call(value_node, trail + [key], found)
        end
      when Psych::Nodes::Sequence, Psych::Nodes::Document
        node.children.each { |child| duplicates_in.call(child, trail, found) }
      end
      found
    end

    offenders = I18n.available_locales.to_h do |locale|
      path = Rails.root.join("config/locales/#{locale}.yml")
      [locale, duplicates_in.call(YAML.parse_file(path), [], [])]
    end.reject { |_, found| found.empty? }

    expect(offenders).to eq({})
  end
end
