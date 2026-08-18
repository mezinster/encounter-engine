require "rails_helper"

# Option carries a translatable `text`, so Game#missing_translations demands one
# per declared locale before a multilingual game may leave draft. Until this
# screen existed there was nowhere to provide it: a bilingual game with a quiz
# level could not be published by ANY sequence of author actions, and the
# missing-translations panel offered a link that went nowhere because
# missing_translation_path_for had no Option branch.
describe "translating a quiz question's options", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author, :is_draft => true); g.update_column(:available_locales, "ru,en"); g }
  let(:level)  { create_level(:game => game) }
  let(:question) { level.questions.first }

  let!(:paris) { Option.create!(:question => question, :text => "Париж", :is_correct => true) }
  let!(:lyon)  { Option.create!(:question => question, :text => "Лион") }

  before { put login_path, :params => { :email => author.email, :password => "1234" } }

  def options_path(params = {})
    game_level_question_options_path(game, level, question, params)
  end

  it "offers a language tab for each declared locale" do
    get options_path

    expect(response.body).to include(I18n.t("locales.en"))
    expect(response.body).to include(I18n.t("locales.ru"))
  end

  it "shows an input per option on a translation tab, beside the original" do
    get options_path(:tab => "en")

    expect(response.body).to include("Париж")
    expect(response.body).to include(%{name="option_translations[#{paris.id}]"})
    expect(response.body).to include(%{name="option_translations[#{lyon.id}]"})
  end

  # The add form belongs to the primary language only: an option existing in one
  # language and not another is a shape the publish gate rejects anyway.
  it "does not offer the add form on a translation tab" do
    get options_path(:tab => "en")

    expect(response.body).not_to include(I18n.t("options.index.new_option_label"))
  end

  it "saves a translation for every option in one submit" do
    patch translations_game_level_question_options_path(game, level, question),
          :params => { :locale => "en",
                       :option_translations => { paris.id.to_s => "Paris", lyon.id.to_s => "Lyon" } }

    expect(paris.reload.translated(:text, "en")).to eq("Paris")
    expect(lyon.reload.translated(:text, "en")).to eq("Lyon")
  end

  it "leaves the primary text alone" do
    patch translations_game_level_question_options_path(game, level, question),
          :params => { :locale => "en", :option_translations => { paris.id.to_s => "Paris" } }

    expect(paris.reload.text).to eq("Париж")
  end

  it "ignores a locale the game has not declared" do
    patch translations_game_level_question_options_path(game, level, question),
          :params => { :locale => "ka", :option_translations => { paris.id.to_s => "პარიზი" } }

    expect(paris.reload.translated(:text, "ka")).not_to eq("პარიზი")
  end

  # A crafted submit naming an option on somebody else's question must not write
  # to it. find_options scopes to @question, and the action only walks that set.
  it "ignores an option id belonging to another question" do
    other = Option.create!(:question => create_level.questions.first, :text => "Чужой")

    patch translations_game_level_question_options_path(game, level, question),
          :params => { :locale => "en", :option_translations => { other.id.to_s => "Hijacked" } }

    expect(other.reload.translated(:text, "en")).not_to eq("Hijacked")
  end

  # THE point of the whole screen.
  it "lets a bilingual game with a quiz level finally be published" do
    game.translations_attributes = { "en" => { "name" => "G", "description" => "D" } }
    game.save!(:validate => false)
    level.translations_attributes = { "en" => { "name" => "L", "text" => "T" } }
    level.save!

    expect(game.reload.missing_translations).not_to be_empty

    patch translations_game_level_question_options_path(game, level, question),
          :params => { :locale => "en",
                       :option_translations => { paris.id.to_s => "Paris", lyon.id.to_s => "Lyon" } }

    expect(game.reload.missing_translations).to be_empty

    game.visibility = "listed"
    expect(game).to be_valid
  end
end

describe ApplicationHelper, "#missing_translation_path_for", type: :helper do
  # Options were the only record type whose missing translation blocked
  # publication AND had no clickable route to fix it.
  it "points an Option entry at its question's options page, on the right tab" do
    game = create_game
    game.update_column(:available_locales, "ru,en")
    level = create_level(:game => game)
    question = level.questions.first
    option = Option.create!(:question => question, :text => "Париж", :is_correct => true)

    entry = game.reload.missing_translations.find { |e| e.record == option }
    expect(entry).to be_present

    expect(helper.missing_translation_path_for(entry))
      .to eq(game_level_question_options_path(game, level, question, :tab => entry.locale))
  end
end
