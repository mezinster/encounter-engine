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
      # Draft: this test is about the comma-separated column round-trip, not
      # about translation completeness, and a published game with untranslated
      # locales would now be blocked by the publish gate.
      game = create_game(:is_draft => true)
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

    # Whole-branch review, Finding 6: the old check only looked at
    # ContentTranslation rows scoped to the Game record itself
    # (`ContentTranslation.where(:translatable => self)`), so an author who
    # had translated every level and hint but never touched the game's own
    # name/description could still repoint primary_locale -- after which
    # every level column would hold the OLD primary language while the game
    # claimed the new one, exactly the corruption this guard exists to
    # prevent. It must look at the whole aggregate (game, levels, hints,
    # questions), the same set Game#translatable_records already assembles
    # for the publish gate.
    it "refuses to change the primary locale when a LEVEL has translations, even if the game itself has none" do
      game = create_game(:is_draft => true)
      game.available_locale_list = %w[ru en]
      game.save!
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      ContentTranslation.create!(:translatable => level, :field => "text",
                                 :locale => "en", :value => "Text EN")

      game.primary_locale = "en"

      expect(game).not_to be_valid
      expect(game.errors[:primary_locale]).to be_present
    end
  end
end
