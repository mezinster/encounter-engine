# spec/models/game/locales_spec.rb
require "rails_helper"

describe Game do
  describe "locale declaration" do
    it "defaults an existing game to a single Russian locale" do
      game = create_game
      expect(game.primary_locale).to eq("ru")
      expect(game.available_locale_list).to eq(%w[ru])
    end

    it "round-trips a locale list through the comma-separated column" do
      game = create_game
      game.available_locale_list = %w[ru en ka]
      game.save!
      expect(game.reload.available_locales).to eq("ru,en,ka")
      expect(game.reload.available_locale_list).to eq(%w[ru en ka])
    end

    it "rejects a locale the platform does not know" do
      game = create_game
      game.available_locale_list = %w[ru klingon]
      expect(game).not_to be_valid
      expect(game.errors[:available_locales]).to be_present
    end

    # Without this, an author can untick their own primary language and leave a
    # game whose content the locale resolution can only reach by fallback.
    it "requires the primary locale to be among the available ones" do
      game = create_game
      game.available_locale_list = %w[en ka]
      expect(game).not_to be_valid
      expect(game.errors[:available_locales]).to be_present
    end

    it "allows the primary locale to change while the game is a draft with no translations" do
      game = create_game(:is_draft => true)
      game.available_locale_list = %w[ru en]
      game.primary_locale = "en"
      expect(game).to be_valid
    end

    # Changing it later would silently reinterpret which stored text is primary:
    # the columns would still hold Russian while the game claimed English.
    it "refuses to change the primary locale once a translation exists" do
      game = create_game(:is_draft => true)
      game.available_locale_list = %w[ru en]
      game.save!
      ContentTranslation.create!(:translatable => game, :field => "name",
                                 :locale => "en", :value => "City Quest")
      game.primary_locale = "en"
      expect(game).not_to be_valid
      expect(game.errors[:primary_locale]).to be_present
    end
  end
end
