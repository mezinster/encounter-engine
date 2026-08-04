require "rails_helper"

RSpec.describe "Rails application" do
  it "boots with the expected name" do
    expect(Rails.application.class.module_parent_name).to eq("EncounterEngine")
  end

  it "defaults to Russian" do
    expect(I18n.default_locale).to eq(:ru)
  end

  it "offers Russian and English" do
    expect(I18n.available_locales).to contain_exactly(:ru, :en)
  end
end
