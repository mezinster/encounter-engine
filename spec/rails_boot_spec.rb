require "rails_helper"

RSpec.describe "Rails application" do
  it "boots with the expected name" do
    expect(Rails.application.class.module_parent_name).to eq("EncounterEngine")
  end

  it "defaults to Russian" do
    expect(I18n.default_locale).to eq(:ru)
  end

  it "offers Russian, English, Ukrainian and Georgian" do
    # uk and ka were registered by task 12 ("register them now, translate
    # later" -- see config/application.rb and config/locales/{uk,ka}.yml):
    # available for selection even though most of their copy still falls
    # back to Russian.
    expect(I18n.available_locales).to contain_exactly(:ru, :en, :uk, :ka)
  end
end
