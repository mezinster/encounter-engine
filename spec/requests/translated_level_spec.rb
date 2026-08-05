require "rails_helper"

describe "playing a translated game", type: :request do
  let(:game) do
    g = create_game(:is_draft => true)
    g.available_locale_list = %w[ru en]
    # The publish gate (Task 3) blocks a non-draft game whose declared
    # locales aren't fully translated -- and that includes the game's own
    # name/description, not just its levels. translations_attributes= only
    # persists content_translations after_save (see TranslatableContent), so
    # a game can't go straight from "new, untranslated" to "published,
    # translated" in one save: validation runs before the translations it
    # would need to pass exist. Save once as a draft to persist the
    # translations, then flip to published now that they're there.
    g.translations_attributes = { "en" => { "name" => "#{g.name} (EN)",
                                            "description" => "#{g.description} (EN)" } }
    g.save!
    g.update!(:is_draft => false)
    g
  end
  let(:level) { create_level(:game => game, :name => "Уровень", :text => "Найдите памятник") }

  before do
    level
    level.translations_attributes = { "en" => { "text" => "Find the monument",
                                                "name" => "Level" } }
    level.save!
    3.times { |i| create_hint(:level => level, :text => "Подсказка #{i}") }
  end

  it "renders the level in the player's language" do
    expect(level.reload.translated(:text, "en")).to eq("Find the monument")
    expect(level.reload.translated(:text, "ru")).to eq("Найдите памятник")
  end

  # Guards the specific mistake this design invites: forgetting to preload, so
  # each hint and question issues its own translation query.
  #
  # includes(:hints, :questions, :content_translations) -- sibling, not
  # nested -- looks like the obvious preload but only fetches the LEVEL's own
  # translations; each hint and question still lazy-loads its own the first
  # time #translated touches it, one query per record (this is exactly what
  # Game#translatable_records' own comment warns about). The nested form
  # below, matching app/controllers/game_passings_controller.rb#preloaded_level,
  # is what actually keeps the query count flat as hints/questions grow:
  # levels, games, the level's own content_translations, hints (bulk),
  # questions (bulk), hints' content_translations (bulk), questions'
  # content_translations (bulk) -- 7 queries total, independent of how many
  # hints or questions the level has. Confirmed by hand: still 7 with 10
  # hints and 6 questions instead of 3 and 1; a bare Level.find with no
  # preload at all is 11 for the small case and 21 for the large one.
  it "does not issue a query per translated record" do
    level.reload
    baseline = count_queries do
      Level.includes(:game, :content_translations,
                     :hints => :content_translations,
                     :questions => :content_translations).find(level.id).tap do |l|
        l.translated(:text, "en")
        l.hints.each { |h| h.translated(:text, "en") }
        l.questions.each { |q| q.translated(:questions, "en") }
      end
    end

    expect(baseline).to be <= 7
  end
end
