require "rails_helper"

describe "authoring translations", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  it "saves a level translation submitted from the English tab" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
    level.save!

    expect(level.reload.translated(:name, "en")).to eq("Level")
    expect(level.reload.translated(:text, "en")).to eq("Text")
    expect(level.reload.name).to eq("Уровень")
  end

  it "saves a game translation without touching the primary columns" do
    game.translations_attributes = { "en" => { "name" => "City Quest",
                                               "description" => "A quest" } }
    game.save!

    expect(game.reload.translated(:name, "en")).to eq("City Quest")
    expect(game.reload.name).not_to eq("City Quest")
  end
end
