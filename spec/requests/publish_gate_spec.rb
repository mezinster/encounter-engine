require "rails_helper"

describe "the publish gate", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  it "lists every missing field with a locale and a label" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    create_hint(:level => level, :text => "Подсказка")

    entries = game.missing_translations
    expect(entries).to be_present
    entries.each do |entry|
      expect(entry.locale).to eq("en")
      expect(entry.label).to be_present
      expect(entry.field).to be_present
      expect(entry.record).to be_present
    end
  end

  it "refuses publication and explains why" do
    create_level(:game => game, :name => "Уровень", :text => "Текст")
    game.is_draft = false
    expect(game.save).to be false
    expect(game.errors[:base].join).to be_present
  end

  it "permits publication once every declared locale is complete" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    game.translations_attributes = { "en" => { "name" => "Quest", "description" => "Desc" } }
    game.save!
    level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
    level.save!

    game.reload.is_draft = false
    expect(game.save).to be true
  end
end
