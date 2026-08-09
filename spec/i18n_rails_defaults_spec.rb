require "rails_helper"

describe "rails-i18n defaults" do
  # The gem must fill GAPS, never override this app's own wording. Load order
  # is what guarantees that -- the gem's files enter I18n.load_path before
  # config/locales/*.yml -- and this is the example that proves it.
  #
  # Only FOUR key paths exist in both config/locales/ru.yml and the gem's
  # ru.yml (activerecord.errors.messages.record_invalid, date.month_names,
  # time.formats.long, time.formats.short), and on only two of them do the two
  # values actually differ. Those two are therefore the ONLY places in this
  # app where a load-order inversion could ever be visible, which is why this
  # example pins them specifically rather than picking a validation message at
  # random. A key the gem does not define cannot demonstrate anything about
  # precedence, however app-authored it looks.
  it "does not override this app's own Russian wording where both define the same key" do
    I18n.with_locale(:ru) do
      # rails-i18n says "%d %b, %H:%M" here. Sixteen l() calls in views render
      # through these formats, so an inversion would silently restyle dates
      # across the app.
      expect(I18n.t("time.formats.short")).to eq("%Y-%m-%d %H:%M")

      # rails-i18n says "Возникли ошибки: %{errors}" here.
      expect(I18n.t("activerecord.errors.messages.record_invalid")).to eq("Запись недействительна")
    end
  end

  # Separate from the precedence check above, and proving something weaker on
  # purpose: these keys are app-only (the gem defines nothing at either path),
  # so this cannot detect an inversion. It detects the app's own wording going
  # missing, which adding a gem full of validation messages makes easy to do
  # without noticing.
  it "still answers with this app's own validation wording" do
    I18n.with_locale(:ru) do
      expect(I18n.t("activerecord.errors.messages.blank")).to eq("не может быть пустым")
      expect(I18n.t("activerecord.errors.models.game.attributes.name.blank"))
        .to eq("Вы не ввели название")
    end
  end

  # The point of the gem: locales this app has never written a line for still
  # get real dates and real validation messages.
  it "supplies dates and validation messages for the new locales" do
    %i[tr be pl].each do |locale|
      I18n.with_locale(locale) do
        expect(I18n.l(Date.new(2026, 3, 1), :format => :long)).to be_present
        expect(I18n.l(Date.new(2026, 3, 1), :format => :long)).not_to include("translation missing")
        expect(I18n.t("errors.messages.blank")).not_to include("translation missing")
      end
    end
  end

  # The landmine this removes. Rails' built-in pluralizer knows one/other only;
  # Slavic locales need CLDR rules or I18n::InvalidPluralizationData is raised
  # the first time anyone writes a pluralised key. Note that :ru is in this
  # list -- before the gem, the DEFAULT locale had no plural data either.
  it "can pluralise in the Slavic locales" do
    %i[ru uk be pl].each do |locale|
      I18n.with_locale(locale) do
        expect {
          I18n.t("datetime.distance_in_words.x_days", :count => 3)
        }.not_to raise_error
      end
    end
  end
end
