require "rails_helper"

describe Translation::Unit do
  let(:game)  { create_game(:name => "Ночной город", :description => "Городская игра") }
  let!(:level) { create_level(:game => game, :name => "Первый", :text => "Найдите табличку 4417") }
  let!(:hint)  { create_hint(:level => level, :text => "Смотрите выше", :delay => 10) }

  it "keys a field unambiguously by class, id and field name" do
    expect(described_class.field_key(level, "name")).to eq("Level##{level.id}.name")
    expect(described_class.field_key(hint, "text")).to eq("Hint##{hint.id}.text")
  end

  it "builds a game-header unit carrying only the game's own fields" do
    fields = game.missing_translated_fields_in("en").select { |f| f.record == game }
    unit   = described_class.for_game(game, fields)

    expect(unit.key).to eq("Game##{game.id}")
    expect(unit.source_text).to include("Ночной город").and include("Городская игра")
    expect(unit.fields.map(&:field)).to match_array(%w[name description])
  end

  # The level subtree is the cacheable unit AND the context unit: a hint that
  # says "смотрите выше" is meaningless without the level text it refers to,
  # so both ride the same prompt.
  it "builds a level unit carrying the level, its hints and its options" do
    fields = game.missing_translated_fields_in("en").select do |f|
      f.record == level || f.record.try(:level) == level
    end
    unit = described_class.for_level(level, fields)

    expect(unit.key).to eq("Level##{level.id}")
    expect(unit.source_text).to include("Найдите табличку 4417").and include("Смотрите выше")
    expect(unit.source_text).to include(described_class.field_key(hint, "text"))
  end

  it "carries no unit at all when nothing in the subtree is missing" do
    expect(described_class.for_level(level, [])).to be_nil
  end
end
