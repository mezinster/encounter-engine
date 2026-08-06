require "rails_helper"

describe "quiz options and the publish gate", type: :request do
  let(:author) { create_user }

  def multilingual_game_with_an_option
    game = create_game(:author => author, :is_draft => true)
    game.update!(:available_locale_list => %w[ru en])
    level = create_level(:game => game)
    question = create_question(:level => level)
    option = create_option(:question => question, :text => "Париж", :is_correct => true)
    [ game, level, option ]
  end

  # Without this a game declaring Ukrainian would show Ukrainian task text
  # above Russian options, with nothing to indicate anything was wrong -- the
  # failure landing on a player mid-game rather than the author beforehand.
  it "refuses to publish a multilingual game whose options are untranslated" do
    game, _level, option = multilingual_game_with_an_option

    game.is_draft = false

    expect(game.valid?).to be false
    expect(game.missing_translations.map(&:record)).to include(option)
  end

  it "names the option in the missing-translations list rather than leaving it blank" do
    game, _level, _option = multilingual_game_with_an_option

    missing = game.missing_translations.find { |m| m.record.is_a?(Option) }

    expect(missing).not_to be_nil
    expect(missing.label).to be_present
    expect(missing.label).to include("Париж")
  end

  it "allows publication once every option is translated" do
    game, level, option = multilingual_game_with_an_option

    # translations_attributes=, not translations= -- see TranslatableContent.
    game.translations_attributes = { "en" => { "name" => "G", "description" => "D" } }
    game.save!
    level.translations_attributes = { "en" => { "name" => "L", "text" => "T" } }
    level.save!
    option.translations_attributes = { "en" => { "text" => "Paris" } }
    option.save!

    game.reload.is_draft = false

    expect(game.valid?).to be true
  end
end
