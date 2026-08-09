require "rails_helper"

RSpec.describe "Rails application" do
  it "boots with the expected name" do
    expect(Rails.application.class.module_parent_name).to eq("EncounterEngine")
  end

  it "defaults to Russian" do
    expect(I18n.default_locale).to eq(:ru)
  end

  it "offers seven languages" do
    # Registration and translation are deliberately separate steps here. uk and
    # ka were registered by task 12 ("register them now, translate later") and
    # have since been translated in full; tr, be and pl were registered on
    # 2026-08-09 and are still endonym-only, so most of their copy falls back
    # to Russian -- see config/application.rb and
    # docs/superpowers/plans/2026-08-09-locale-translation-delivery.md.
    #
    # This list is pinned rather than derived because it is a product decision,
    # not an implementation detail: a locale appearing here is offered to every
    # user in the switcher and to every game author as a content-translation
    # tab. Adding one should have to change this line.
    expect(I18n.available_locales).to contain_exactly(:ru, :en, :uk, :ka, :tr, :be, :pl)
  end
end
