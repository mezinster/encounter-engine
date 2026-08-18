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

    it "reports untranslated level and hint fields" do
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      create_hint(:level => level, :text => "Подсказка")
      create_question(:level => level)

      records = game.missing_translations.map(&:record)
      expect(records).to include(level)
      expect(records.map(&:class).uniq).to include(Level, Hint)
    end

    # Question::TRANSLATABLE_FIELDS is deliberately empty (see app/models/question.rb):
    # the `questions` column is vestigial, written and rendered nowhere in this app.
    # Listing it would make this method demand a translation no author can ever
    # supply, permanently blocking any multilingual game that has questions from
    # leaving draft -- exactly the lock the "publish gate" examples below prove is
    # gone.
    it "never reports a question, since a question has no translatable content" do
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      create_question(:level => level)

      records = game.missing_translations.map(&:record)
      expect(records.map(&:class).uniq).not_to include(Question)
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
      complete.visibility = "listed"
      expect(complete).to be_valid
    end

    # This is a race: a team reaching a level it cannot read loses the leg.
    it "refuses to leave draft while a declared locale is incomplete" do
      create_level(:game => game, :name => "Уровень", :text => "Текст")
      game.visibility = "listed"
      expect(game).not_to be_valid
      expect(game.errors[:base]).to be_present
    end

    it "still allows a draft game to be saved while incomplete" do
      create_level(:game => game, :name => "Уровень", :text => "Текст")
      expect(game).to be_valid
    end

    it "refuses a game created directly as published while a locale is incomplete" do
      g = Game.new(:name => "Новая", :description => "Описание", :author => create_user,
                   :max_team_number => 5, :starts_at => Time.now + 1.day, :visibility => "listed")
      g.primary_locale = "ru"
      g.available_locale_list = %w[ru en]
      expect(g).not_to be_valid
      expect(g.errors[:base]).to be_present
    end

    it "refuses to add a locale to an already-published game without translating it" do
      published = create_game(:is_draft => false)
      create_level(:game => published)
      published.available_locale_list = %w[ru en]
      expect(published).not_to be_valid
      expect(published.errors[:base]).to be_present
    end

    it "lets a multilingual game with questions leave draft once its levels are translated" do
      game = create_game(:is_draft => true)
      game.available_locale_list = %w[ru en]
      game.save!
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      create_question(:level => level)
      game.translations_attributes = { "en" => { "name" => "Quest", "description" => "Desc" } }
      game.save!
      level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
      level.save!

      game.reload.visibility = "listed"
      expect(game.save).to be true
    end
  end
end
