require "rails_helper"

# The play screen has had a content-language switcher since the AI-translation
# work; this covers the game page's own, which is reachable when the game is
# NOT running -- the state the play-screen route refuses. See the plan at
# docs/superpowers/plans/2026-08-18-content-locale-switcher-on-game-page.md.
describe "switching content language from the game page", type: :request do
  # Mirrors spec/requests/translated_level_spec.rb: create_user builds every
  # user with password "1234".
  def login(user)
    post login_path, :params => { :email => user.email, :password => "1234" }
  end

  let(:author) { create_user }

  # A draft, and deliberately so: ensure_author_if_game_draft keeps a draft
  # author-only, and a stopped draft is exactly the state in which the owner
  # got stuck in Turkish.
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en tr]
    g.save!
    g
  end

  it "stores the chosen locale for the signed-in user" do
    login(author)

    post set_content_locale_game_path(game, :locale => "en")

    preference = GameLocalePreference.find_by(:user_id => author.id, :game_id => game.id)
    expect(preference&.locale).to eq("en")
  end

  it "redirects back to the game page" do
    login(author)

    post set_content_locale_game_path(game, :locale => "en")

    expect(response).to redirect_to(game_path(game))
  end

  it "updates the one row rather than accumulating a row per switch" do
    login(author)

    post set_content_locale_game_path(game, :locale => "tr")
    post set_content_locale_game_path(game, :locale => "en")

    rows = GameLocalePreference.where(:user_id => author.id, :game_id => game.id)
    expect(rows.count).to eq(1)
    expect(rows.first.locale).to eq("en")
  end

  # content_locale_for already ignores an undeclared locale at read time; this
  # keeps one from being written at all, so the row never has to be cleaned up
  # after an author narrows available_locales.
  it "writes nothing for a locale the game does not offer" do
    login(author)

    post set_content_locale_game_path(game, :locale => "ka")

    expect(GameLocalePreference.where(:game_id => game.id)).to be_empty
  end

  it "sends a signed-out visitor to the login page and writes nothing" do
    post set_content_locale_game_path(game, :locale => "en")

    expect(response).to redirect_to(login_path)
    expect(GameLocalePreference.count).to eq(0)
  end

  # The regression this whole change exists for. Both requests are the same
  # intent; only the game-page route is reachable while the game is stopped.
  it "works on a stopped draft, where the play-screen route answers 401" do
    login(author)

    post set_content_locale_path(:game_id => game.id, :locale => "en")
    expect(response).to have_http_status(:unauthorized)
    expect(GameLocalePreference.count).to eq(0)

    post set_content_locale_game_path(game, :locale => "en")
    expect(GameLocalePreference.count).to eq(1)
  end

  # Same visibility rule as games#show: a stranger cannot see this draft, so
  # they cannot record a reading preference for it either.
  it "refuses a draft belonging to somebody else" do
    login(create_user)

    post set_content_locale_game_path(game, :locale => "en")

    expect(response).to have_http_status(:unauthorized)
    expect(GameLocalePreference.count).to eq(0)
  end
end
