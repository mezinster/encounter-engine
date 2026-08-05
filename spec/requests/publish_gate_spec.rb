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

  # These exercise the actual deliverable of this task -- the rendered
  # "what is missing" block on games#show -- not just the model-level
  # Game#missing_translations behaviour already covered by
  # spec/models/game/missing_translations_spec.rb. In particular, the first
  # example is the regression guard for the Critical ?locale= vs ?tab= bug:
  # it fails if missing_translation_path_for ever goes back to building a
  # deep link with :locale instead of :tab (verified by temporarily
  # reverting the helper and watching this fail -- see task-8-report.md).
  describe "the missing-translations block on games#show" do
    def login(user)
      post login_path, params: { email: user.email, password: "1234" }
    end

    # The header's own language switcher (app/views/layouts/_header.html.erb)
    # legitimately puts ?locale=en links on every page, unrelated to this
    # feature -- so the "never ?locale=" assertion has to be scoped to the
    # missing-translations block itself, not the whole response body.
    it "links to the missing locale's tab, never to ?locale=" do
      login(author)
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      create_hint(:level => level, :text => "Подсказка")

      get game_path(game)

      block = response.body[/<div class="missing-translations">.*?<\/div>/m]
      expect(block).to be_present
      expect(block).to include("tab=en")
      expect(block).not_to include("locale=en")
    end

    it "renders nothing once every declared locale is fully translated" do
      login(author)
      level = create_level(:game => game, :name => "Уровень", :text => "Текст")
      game.translations_attributes = { "en" => { "name" => "Quest", "description" => "Desc" } }
      game.save!
      level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
      level.save!

      get game_path(game)

      expect(response.body).not_to include("missing-translations")
    end

    it "renders nothing for a single-locale game" do
      login(author)
      solo_game = create_game(:author => author, :is_draft => true)
      create_level(:game => solo_game, :name => "Уровень", :text => "Текст")
      expect(solo_game.multilingual?).to eq(false)

      get game_path(solo_game)

      expect(response.body).not_to include("missing-translations")
    end
  end
end
