require "rails_helper"

describe "the language tab strip", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "marks the active language as text, not a link, so it is distinguishable without CSS" do
    sign_in(author)
    get edit_game_path(game, :tab => "en")

    strip = response.body[/<ul class="language-tabs">.*?<\/ul>/m]
    expect(strip).to be_present
    # The active language is not a link...
    expect(strip).to match(/<span class="current">\s*English/)
    # ...and the inactive one still is, pointing at ?tab=
    expect(strip).to match(/<a [^>]*href="[^"]*tab=ru/)
  end

  it "renders no strip at all for a single-locale game" do
    single = create_game(:author => author, :is_draft => true)
    sign_in(author)
    get edit_game_path(single)
    expect(response.body).not_to include("language-tabs")
  end
end

describe "the authoring form on an untranslated tab", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end
  let(:level) { create_level(:game => game, :name => "DragonLair", :text => "TaskBody") }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Reported from production: opening ?tab=en showed the RUSSIAN text in both
  # fields, because the form bound to #translated, which falls back to the
  # primary column. The author could not tell the translation was missing.
  it "shows empty fields, not the primary language's text" do
    level
    sign_in(author)
    get edit_game_level_path(game, level, :tab => "en")

    # Scoped to the input itself: the level's name also appears in the page
    # heading, so asserting on the whole body cannot tell us what the FIELD
    # holds -- which is the only thing this bug was ever about.
    name_input = response.body[/<input[^>]*name="level\[translations\]\[en\]\[name\]"[^>]*>/]
    expect(name_input).to be_present
    expect(name_input).not_to include("DragonLair")

    task_textarea = response.body[/<textarea[^>]*name="level\[translations\]\[en\]\[text\]"[^>]*>(.*?)<\/textarea>/m, 1]
    expect(task_textarea.to_s.strip).to be_empty
  end

  it "still shows the author's own text on the primary tab" do
    level
    sign_in(author)
    get edit_game_level_path(game, level, :tab => "ru")
    expect(response.body).to include("DragonLair")
  end

  # The consequence of the fallback: saving the form untouched persisted the
  # Russian text as the English translation, satisfying the publish gate with
  # content that was never translated.
  it "does not let an untouched save pass the primary text off as a translation" do
    level
    expect(level.translated?(:name, "en")).to be false
    expect(level.translation_draft(:name, "en")).to be_nil
  end
end
