require "rails_helper"

# The helper spec pins with_newlines itself. This pins that the five places
# author-written text reaches a page actually call it -- the play screen most
# of all, where a hint arriving as one unbroken wall of prose is read under
# time pressure.
describe "author-written text keeps its line breaks", type: :request do
  let(:author) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "on the author's own screens" do
    let(:game) do
      create_game(:author => author, :is_draft => true,
                  :description => "First paragraph.\nSecond paragraph.")
    end
    let!(:level) do
      create_level(:game => game, :text => "Go to the square.\nLook up.")
    end
    let!(:hint) do
      Hint.create!(:level => level, :delay => 5,
                   :text => "Behind the statue.\nOn the plaque.")
    end

    before { sign_in(author) }

    it "breaks the game description" do
      get game_path(game)

      response.body.should include("First paragraph.<br>Second paragraph.")
    end

    it "breaks the level text" do
      get game_level_path(game, level)

      response.body.should include("Go to the square.<br>Look up.")
    end

    it "breaks the hint text in the level's hint list" do
      get game_level_path(game, level)

      response.body.should include("Behind the statue.<br>On the plaque.")
    end
  end

  describe "on the play screen" do
    let(:game) { create_game(:author => author, :is_draft => true) }
    let!(:level) do
      create_level(:game => game, :text => "Find the fountain.\n\nCount the fish.")
    end
    let!(:hint) do
      Hint.create!(:level => level, :delay => 0,
                   :text => "It is bronze.\nNot marble.")
    end
    let(:captain) { create_user }

    before do
      sign_in(author)
      post start_test_game_path(game)
      game.reload
      delete logout_path

      captain.update!(:team => create_team(:captain => captain))
      create_game_entry(:game => game, :team => captain.team, :status => "accepted")
      sign_in(captain)
    end

    it "breaks the level text, blank line included" do
      get show_current_level_path(:game_id => game.id)

      response.body.should include("Find the fountain.<br><br>Count the fish.")
    end

    it "breaks the hint text" do
      get show_current_level_path(:game_id => game.id)

      response.body.should include("It is bronze.<br>Not marble.")
    end

    # The content model must not widen just because newlines now render.
    it "still escapes markup an author typed" do
      level.update!(:text => "Careful\n<script>alert(1)</script>")

      get show_current_level_path(:game_id => game.id)

      response.body.should_not include("<script>alert(1)</script>")
      response.body.should include("&lt;script&gt;")
    end
  end

  # A hint used to be a single-line <input>, so there was no way to type a
  # newline into one at all -- the render change alone would have had nothing
  # to render.
  it "gives the hint form a textarea rather than a single-line input" do
    game  = create_game(:author => author, :is_draft => true)
    level = create_level(:game => game)
    sign_in(author)

    get new_game_level_hint_path(game, level)

    response.body.should include("<textarea")
    response.body.should_not match(/<input[^>]*name="hint\[text\]"/)
  end
end
