require "rails_helper"

describe Game do
  let(:game) do
    g = create_game(:is_draft => true, :name => "Квест", :description => "Описание")
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  describe "#missing_translations" do
    it "is empty for a single-locale game" do
      single = create_game(:is_draft => true)
      create_level(:game => single)
      expect(single.missing_translations).to eq([])
    end

    it "reports the game's own untranslated fields" do
      missing = game.missing_translations
      expect(missing.map(&:field)).to include("name", "description")
      expect(missing.map(&:locale).uniq).to eq(%w[en])
    end

    it "reports untranslated level, hint and question fields" do
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      create_hint(:level => level, :text => "Подсказка")
      create_question(:level => level)

      records = game.missing_translations.map(&:record)
      expect(records).to include(level)
      expect(records.map(&:class).uniq).to include(Level, Hint, Question)
    end

    it "stops reporting a field once it is translated" do
      game.translations_attributes = { "en" => { "name" => "Quest",
                                                 "description" => "Description" } }
      game.save!
      expect(game.reload.missing_translations.map(&:field)).not_to include("name")
    end

    it "carries a human label so the author can find the field" do
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      entry = game.missing_translations.detect { |m| m.record == level && m.field == "text" }
      expect(entry.label).to be_present
    end
  end

  describe "the publish gate" do
    it "lets a complete game leave draft" do
      complete = create_game(:is_draft => true)
      create_level(:game => complete)
      complete.is_draft = false
      expect(complete).to be_valid
    end

    # This is a race: a team reaching a level it cannot read loses the leg.
    it "refuses to leave draft while a declared locale is incomplete" do
      create_level(:game => game, :name => "Уровень", :text => "Текст")
      game.is_draft = false
      expect(game).not_to be_valid
      expect(game.errors[:base]).to be_present
    end

    it "still allows a draft game to be saved while incomplete" do
      create_level(:game => game, :name => "Уровень", :text => "Текст")
      expect(game).to be_valid
    end
  end
end
