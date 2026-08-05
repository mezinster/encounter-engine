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
