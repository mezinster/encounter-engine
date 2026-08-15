require "rails_helper"

# Reported from production: a game left in test mode was listed on the public
# home page as RUNNING, its profile was readable by a logged-off visitor, and
# that profile offered «Старт» and «Завершить тестирование» to anyone.
#
# Root cause: start_test clears is_draft so the game behaves as live. Until
# then a draft was kept off every list by Game.visible (non_drafts) and off its
# own page by ensure_author_if_game_is_draft. Both protections stop applying
# the moment a test begins, and nothing replaced them -- so a rehearsal of an
# unpublished game became public.
#
# The codebase already disagreed with itself here: shared/_current_games
# .html.erb skips testing games deliberately, but the public list never got
# the same treatment.
describe "a game in test mode is not public", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }
  let!(:level)     { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
    game.is_testing.should be true
    delete logout_path
  end

  describe "the listings" do
    it "keeps it off the home page for a logged-off visitor" do
      get root_path

      response.body.should_not include(game.name)
    end

    it "keeps it off /games for a logged-off visitor" do
      get games_path

      response.body.should_not include(game.name)
    end

    it "keeps it off the listings for a logged-in stranger too" do
      sign_in(create_user)

      get root_path
      response.body.should_not include(game.name)

      get games_path
      response.body.should_not include(game.name)
    end

    # The author reaches their own games through Game.by(current_user) on the
    # dashboard, not through Game.visible, so tightening that scope must not
    # hide an author's game from them.
    it "still shows the author their own game on the dashboard" do
      sign_in(author)

      get dashboard_path

      response.body.should include(game.name)
    end

    it "lists the game again once the test finishes" do
      sign_in(author)
      post finish_test_game_path(game)
      # finish_test returns it to draft; publish it as an author would.
      game.reload.update!(:is_draft => false)
      delete logout_path

      get root_path

      response.body.should include(game.name)
    end
  end

  describe "the game page" do
    it "refuses a logged-off visitor" do
      get game_path(game)

      response.should have_http_status(:unauthorized)
    end

    it "refuses a logged-in stranger" do
      sign_in(create_user)

      get game_path(game)

      response.should have_http_status(:unauthorized)
    end

    it "admits the author" do
      sign_in(author)

      get game_path(game)

      response.should have_http_status(:ok)
    end

    it "admits a superadmin" do
      sign_in(superadmin)

      get game_path(game)

      response.should have_http_status(:ok)
    end

    # Test-run invitations put people other than the author into a test. They
    # must still be able to read the game they were invited to.
    it "admits an admitted tester" do
      tester = create_user
      create_test_admission(:run => game.current_run, :team => create_team,
                            :user => tester)
      sign_in(tester)

      get game_path(game)

      response.should have_http_status(:ok)
    end
  end

  describe "the in-test controls" do
    it "offers the author both" do
      sign_in(author)

      get game_path(game)

      response.body.should include(show_current_level_path(:game_id => game.id))
      response.body.should include(finish_test_game_path(game))
    end

    # finish_test is behind ensure_author and deletes every passing and log
    # line in the run. A tester pressing it gets a 401 -- a button that cannot
    # work should not be drawn.
    # It used to be the last thing on the page, under «Удалить эту игру», which
    # is where an author who had just admitted someone went looking for them
    # and did not find them. Asserted as an ordering rather than a presence,
    # because presence was already true when the bug was reported.
    it "puts the admissions panel above the delete button for the author" do
      sign_in(author)

      get game_path(game)

      panel  = response.body.index("Допуск к тестированию")
      delete = response.body.index(delete_game_path(game))

      panel.should_not be_nil
      delete.should_not be_nil
      panel.should be < delete
    end

    it "renders the panel exactly once for the author" do
      sign_in(author)

      get game_path(game)

      response.body.scan("Допуск к тестированию").size.should == 1
    end

    # author_of? is strict, so the author block does not render for an operator
    # on somebody else's game -- the panel has to reach them the other way.
    it "still reaches a superadmin who is not the author" do
      sign_in(superadmin)

      get game_path(game)

      response.body.scan("Допуск к тестированию").size.should == 1
    end

    it "offers a tester the play link but not the finish button" do
      tester = create_user
      create_test_admission(:run => game.current_run, :team => create_team,
                            :user => tester)
      sign_in(tester)

      get game_path(game)

      response.body.should include(show_current_level_path(:game_id => game.id))
      response.body.should_not include(finish_test_game_path(game))
    end
  end
end
