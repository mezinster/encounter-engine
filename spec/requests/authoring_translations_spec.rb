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

  it "saves a hint translation" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    hint = create_hint(:level => level, :text => "Подсказка")
    hint.translations_attributes = { "en" => { "text" => "Hint" } }
    hint.save!

    expect(hint.reload.translated(:text, "en")).to eq("Hint")
    expect(hint.reload.text).to eq("Подсказка")
  end

  it "saves a question translation" do
    level = create_level(:game => game, :name => "Уровень", :text => "Текст")
    question = create_question(:level => level)
    question.translations_attributes = { "en" => { "questions" => "What colour is the door?" } }
    question.save!

    expect(question.reload.translated(:questions, "en")).to eq("What colour is the door?")
  end

  # Round 2 review: the two examples above only prove the model-level
  # contract (Task 2's writer). Neither exercises an actual HTTP request, so
  # neither would have caught the params-shape bugs in games_controller /
  # levels_controller (or the ?tab vs ?locale collision below). These do.
  describe "through the real controllers" do
    def login(user)
      post login_path, params: { email: user.email, password: "1234" }
    end

    it "declares a game's languages, then saves a level translation from the English tab, leaving primary columns untouched" do
      login(author)
      solo_game = create_game(:author => author, :is_draft => true)

      put game_path(solo_game), params: {
        game: {
          name: solo_game.name, description: solo_game.description,
          max_team_number: solo_game.max_team_number, visibility: "draft",
          primary_locale: "ru", :available_locale_list => %w[ru en]
        }
      }
      expect(solo_game.reload.available_locale_list).to match_array(%w[ru en])
      expect(solo_game.reload.primary_locale).to eq("ru")

      level = create_level(:game => solo_game, :name => "Уровень", :text => "Текст")

      put "#{game_level_path(solo_game, level)}?tab=en", params: {
        level: {
          translations: { "en" => { "name" => "Level", "text" => "Text" } }
        }
      }

      expect(level.reload.translated(:name, "en")).to eq("Level")
      expect(level.reload.translated(:text, "en")).to eq("Text")
      expect(level.reload.name).to eq("Уровень")
      expect(level.reload.text).to eq("Текст")
    end

    # This is the Critical bug's exact reproduction: the platform's
    # pre-existing chrome switcher (app/views/layouts/_header.html.erb) uses
    # ?locale=, on every page, for a purpose that has nothing to do with
    # this feature. Before the fix, levels/edit and games/edit read that
    # same param to pick the active translation tab, so clicking the chrome
    # switcher on a single-locale game's edit form silently rebound the
    # inputs from the model's own columns to a translation hash the game
    # never declared -- an edit that looked like it saved but never touched
    # the primary column.
    it "still binds the level form to the primary columns when ?locale=en is present (single-locale game)" do
      login(author)
      solo_game = create_game(:author => author, :is_draft => true)
      level = create_level(:game => solo_game, :name => "Уровень", :text => "Текст")
      expect(solo_game.multilingual?).to eq(false)

      get "#{edit_game_level_path(solo_game, level)}?locale=en"

      expect(response.body).to include("level[name]")
      expect(response.body).to include("level[text]")
      expect(response.body).not_to include("level[translations]")
      expect(response.body).not_to include("language-tabs")
    end

    it "still binds the game form to the primary columns when ?locale=en is present (single-locale game)" do
      login(author)
      solo_game = create_game(:author => author, :is_draft => true)
      expect(solo_game.multilingual?).to eq(false)

      get "#{edit_game_path(solo_game)}?locale=en"

      expect(response.body).to include("game[name]")
      expect(response.body).to include("game[description]")
      expect(response.body).not_to include("game[translations]")
      expect(response.body).not_to include("language-tabs")
    end

    # Same reproduction as the level examples above, for the hint form: ?tab=
    # picks the translation tab on a multilingual game...
    it "binds the hint form to the English translation when ?tab=en is present (multilingual game)" do
      login(author)
      multi_game = create_game(:author => author, :is_draft => true)
      multi_game.available_locale_list = %w[ru en]
      multi_game.save!
      level = create_level(:game => multi_game, :name => "Уровень", :text => "Текст")
      hint = create_hint(:level => level, :text => "Подсказка")

      get "#{edit_game_level_hint_path(multi_game, level, hint)}?tab=en"

      expect(response.body).to include("hint[translations][en][text]")
    end

    # ...and ?locale=en, the platform's pre-existing chrome switcher, must not
    # be read for that purpose: the same Critical bug Task 6 hit for the level
    # and game forms (an author's menu-language click silently rebinding the
    # form to a translation hash) is possible here too, since the hint form
    # reaches its game through @level.game the same way.
    it "still binds the hint form to the primary columns when ?locale=en is present (single-locale game)" do
      login(author)
      solo_game = create_game(:author => author, :is_draft => true)
      level = create_level(:game => solo_game, :name => "Уровень", :text => "Текст")
      hint = create_hint(:level => level, :text => "Подсказка")
      expect(solo_game.multilingual?).to eq(false)

      get "#{edit_game_level_hint_path(solo_game, level, hint)}?locale=en"

      expect(response.body).to include("hint[text]")
      expect(response.body).not_to include("hint[translations]")
      expect(response.body).not_to include("language-tabs")
    end
  end
end
