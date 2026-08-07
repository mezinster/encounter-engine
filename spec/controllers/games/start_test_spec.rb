# -*- encoding : utf-8 -*-
require "rails_helper"

# Blocker fix: GamesController#start_test force-starts a scheduled game
# (nulling its registration_deadline) with no author check -- only
# find_game ran before it. See app/controllers/games_controller.rb's
# before_action :ensure_author list.
RSpec.describe GamesController, "#start_test", type: :controller do
  describe "when the game author starts the test" do
    before :each do
      @user = create_user
      @game = create_game :author => @user
    end

    it "puts the game into testing mode and redirects" do
      perform_request(:as_user => @user)
      @game.reload
      expect(@game.is_testing?).to be true
      expect(response).to redirect_to(@game)
    end
  end

  describe "when any other logged-in user attempts to start the test" do
    before :each do
      @user = create_user
      @game = create_game
    end

    it "raises Unauthorized exception and leaves the game untouched" do
      assert_unauthorized { perform_request(:as_user => @user) }
      expect(@game.reload.is_testing?).to be false
    end
  end

  describe "when a guest attempts to start the test" do
    before :each do
      @game = create_game
    end

    it "raises Unauthenticated exception and leaves the game untouched" do
      assert_unauthenticated { perform_request }
      expect(@game.reload.is_testing?).to be false
    end
  end

  # Whole-branch review, Finding 1's fallout: start_test's @game.save! was
  # named as a 500-raising site. It sets is_draft = false, so it runs
  # through the exact save the old, state-only guard (`return if draft?`)
  # broke on. Two cases worth telling apart:
  #   - a game that is ALREADY published and has since acquired a gap (the
  #     fallout case) -- is_draft is false->false here, not a real
  #     transition, so start_test must still succeed
  #   - a DRAFT game with a gap being published through start_test (the
  #     legitimate case) -- is_draft genuinely transitions true->false, so
  #     the gate must still refuse
  describe "when the game has a translation gap" do
    describe "and the game is already published (fallout: must still start)" do
      before :each do
        @user = create_user
        @game = create_game(:author => @user, :is_draft => true)
        @game.available_locale_list = %w[ru en]
        @game.translations_attributes = { "en" => { "name" => "#{@game.name} (EN)",
                                                     "description" => "#{@game.description} (EN)" } }
        @game.save!
        level = create_level(:game => @game, :name => "Уровень", :text => "Текст")
        level.translations_attributes = { "en" => { "name" => "Level", "text" => "Text" } }
        level.save!
        @game.update!(:is_draft => false)

        # Untranslated level added AFTER a clean publication -- the fallout gap.
        create_level(:game => @game, :name => "Уровень 2", :text => "Текст 2")
        @game.reload
      end

      it "still puts the game into testing mode and redirects" do
        perform_request(:as_user => @user)
        @game.reload
        expect(@game.is_testing?).to be true
        expect(response).to redirect_to(@game)
      end
    end

    describe "and the game is still a draft being published through start_test (legitimate refusal)" do
      before :each do
        @user = create_user
        @game = create_game(:author => @user, :is_draft => true)
        @game.available_locale_list = %w[ru en]
        @game.translations_attributes = { "en" => { "name" => "#{@game.name} (EN)",
                                                     "description" => "#{@game.description} (EN)" } }
        @game.save!
        # Never translated -- legitimate while draft, but start_test's
        # is_draft: true -> false transition must still catch it.
        create_level(:game => @game, :name => "Уровень", :text => "Текст")
      end

      # The refusal itself is unchanged; how it surfaces is not. This used to
      # assert raise_error(ActiveRecord::RecordInvalid), which was the old
      # save! behaviour: unrescued, Rails answered 422, and because this app
      # ships no public/422.html the author's browser showed a bare page that
      # read as "page does not exist" -- pointing them at the router for what
      # is actually an unfinished translation. The reason was computed, put in
      # errors[:base], and thrown away by the exception.
      it "refuses to start the test, says why, and leaves the game a draft" do
        expect { perform_request(:as_user => @user) }.not_to raise_error
        expect(response).to redirect_to(@game)
        expect(flash[:alert]).to include(
          I18n.t("games.translations.incomplete", :count => @game.missing_translations.size)
        )

        @game.reload
        expect(@game.is_draft?).to be true
        expect(@game.is_testing?).to be false
      end
    end
  end

  def perform_request(opts={})
    session[:user_id] = opts[:as_user]&.id
    post :start_test, params: { id: @game.id }
    response
  end
end
