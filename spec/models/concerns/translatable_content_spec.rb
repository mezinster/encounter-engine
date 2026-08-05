# spec/models/concerns/translatable_content_spec.rb
require "rails_helper"

describe TranslatableContent do
  # Draft: this file exercises the TranslatableContent concern in isolation,
  # not the publish gate, and most examples here save a level/hint/question
  # while "en"/"ka" are deliberately left untranslated.
  let(:game) do
    g = create_game(:name => "Городской квест", :is_draft => true)
    g.available_locale_list = %w[ru en ka]
    g.save!
    g
  end
  let(:level) { create_level(:game => game, :name => "Уровень", :text => "Найдите памятник") }

  describe "#translated" do
    it "reads the model's own column for the primary locale" do
      expect(level.translated(:text, "ru")).to eq("Найдите памятник")
    end

    it "reads the side table for a non-primary locale" do
      ContentTranslation.create!(:translatable => level, :field => "text",
                                 :locale => "en", :value => "Find the monument")
      expect(level.reload.translated(:text, "en")).to eq("Find the monument")
    end

    # A blank task in the middle of a race is worse than a readable one in the
    # wrong language.
    it "falls back to the column when the locale has no translation" do
      expect(level.translated(:text, "ka")).to eq("Найдите памятник")
    end

    it "falls back when the translation row exists but is blank" do
      ContentTranslation.create!(:translatable => level, :field => "text",
                                 :locale => "ka", :value => "")
      expect(level.reload.translated(:text, "ka")).to eq("Найдите памятник")
    end
  end

  describe "#translated?" do
    it "is true for the primary locale when the column has content" do
      expect(level.translated?(:text, "ru")).to be true
    end

    # Otherwise the publish gate would pass a game whose author left a task
    # description empty in the primary language -- exactly what it exists to catch.
    it "is false for the primary locale when the column is blank" do
      level.update_column(:text, "")
      expect(level.reload.translated?(:text, "ru")).to be false
    end

    it "is false when a non-primary locale has no row" do
      expect(level.translated?(:text, "en")).to be false
    end

    it "is false when a non-primary row exists but is blank" do
      ContentTranslation.create!(:translatable => level, :field => "text",
                                 :locale => "en", :value => "  ")
      expect(level.reload.translated?(:text, "en")).to be false
    end
  end

  describe "#translations_attributes=" do
    it "creates rows for non-primary locales" do
      level.translations_attributes = { "en" => { "text" => "Find the monument",
                                                  "name" => "Level" } }
      level.save!
      expect(level.reload.translated(:text, "en")).to eq("Find the monument")
      expect(level.reload.translated(:name, "en")).to eq("Level")
    end

    it "updates an existing row rather than duplicating it" do
      level.translations_attributes = { "en" => { "text" => "First" } }
      level.save!
      level.translations_attributes = { "en" => { "text" => "Second" } }
      level.save!
      expect(level.reload.translated(:text, "en")).to eq("Second")
      expect(ContentTranslation.where(:translatable => level, :field => "text",
                                      :locale => "en").count).to eq(1)
    end

    # Writing the primary language here would put the same text in two places
    # and let them drift apart.
    it "ignores the primary locale, which belongs in the column" do
      level.translations_attributes = { "ru" => { "text" => "Другой текст" } }
      level.save!
      expect(level.reload.text).to eq("Найдите памятник")
      expect(ContentTranslation.where(:translatable => level, :locale => "ru").count).to eq(0)
    end
  end

  describe "translation_game" do
    it "resolves the owning game from every translatable model" do
      hint     = create_hint(:level => level)
      question = create_question(:level => level)
      expect(level.translation_game).to eq(game)
      expect(hint.translation_game).to eq(game)
      expect(question.translation_game).to eq(game)
      expect(game.translation_game).to eq(game)
    end
  end
end
