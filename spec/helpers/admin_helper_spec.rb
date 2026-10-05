require "rails_helper"

RSpec.describe AdminHelper, type: :helper do
  describe "#admin_tab_current" do
    it "maps an admin controller to its section" do
      allow(helper).to receive(:controller_name).and_return("game_entries")
      expect(helper.admin_tab_current).to eq(:games)
    end

    # A new admin controller left out of the map used to fall back to
    # :dashboard, silently marking «Обзор» as the current tab on its page.
    it "raises for an admin controller missing from the map" do
      allow(helper).to receive(:controller_name).and_return("brand_new_admin_thing")
      expect { helper.admin_tab_current }.to raise_error(KeyError)
    end
  end
end
