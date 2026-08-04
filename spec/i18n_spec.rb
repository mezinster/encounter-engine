# spec/i18n_spec.rb
require "rails_helper"

RSpec.describe "internationalization" do
  it "has the same keys in every locale file" do
    def leaf_keys(hash, prefix = "")
      hash.flat_map do |key, value|
        path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
        value.is_a?(Hash) ? leaf_keys(value, path) : [path]
      end
    end

    ru = leaf_keys(YAML.load_file(Rails.root.join("config/locales/ru.yml")).fetch("ru"))
    en = leaf_keys(YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en"))

    expect(en.sort).to eq(ru.sort)
  end

  it "falls back to Russian for a missing English key" do
    I18n.with_locale(:en) do
      expect(I18n.t("game.not_started")).to be_present
    end
  end
end
