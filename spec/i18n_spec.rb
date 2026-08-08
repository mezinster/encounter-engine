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
  %i[uk ka].each do |locale|
    it "only defines keys that also exist in ru (#{locale}.yml may be an incomplete subset)" do
      data = locale_data(locale)
      expect(data.keys - ru.keys).to eq([])
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
  %i[uk ka].each do |locale|
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
  # whichever locale has the mismatched placeholder. The four locales here
  # are ru, en, uk, ka; uk/ka are partial (see above) so this only compares
  # keys where more than one locale actually defines a value.
  it "uses the same interpolation variables for a key across every locale that defines it" do
    interpolation_vars = ->(value) { value.to_s.scan(/%\{(\w+)\}/).flatten.sort.uniq }

    locales = { ru: ru, en: en, uk: locale_data(:uk), ka: locale_data(:ka) }
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
end
