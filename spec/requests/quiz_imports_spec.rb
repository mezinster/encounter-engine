require "rails_helper"

# The two-step wrapper around QuizImport and QuizImport::Writer: paste →
# preview → confirm. No server-side state carries between the steps; the
# pasted text rides a hidden field.
describe "importing quiz questions", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). create_user sets the
  # password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  let(:valid_text) do
    <<~TEXT
      Раз?
      A) *Да
      B) Нет
      Два?
      A) Да
      B) *Нет
    TEXT
  end

  describe "reaching the form" do
    it "lets the author in" do
      sign_in(author)

      get new_game_quiz_import_path(game)

      expect(response).to have_http_status(:ok)
    end

    # ensure_author admits superadmins, so both halves of the original request
    # ride one filter that already existed.
    it "lets a superadmin in" do
      operator = create_user
      operator.update!(:is_superadmin => true)
      sign_in(operator)

      get new_game_quiz_import_path(game)

      expect(response).to have_http_status(:ok)
    end

    it "refuses a different author" do
      sign_in(create_user)

      get new_game_quiz_import_path(game)

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a guest" do
      get new_game_quiz_import_path(game)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "the link on the game page" do
    it "is offered to the author while the game has not started" do
      sign_in(author)

      get game_path(game)

      expect(response.body).to include(new_game_quiz_import_path(game))
    end

    # Same rule as adding a single level: the importer rides the same guards,
    # so offering it on a started game would be a promise it cannot keep.
    it "is not offered once the game has started" do
      started = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      sign_in(author)

      get game_path(started)

      expect(response.body).not_to include(new_game_quiz_import_path(started))
    end
  end

  describe "previewing" do
    # The whole point of the two-step flow: the author sees what will happen
    # before any of it is real.
    it "writes nothing" do
      sign_in(author)

      expect do
        post game_quiz_import_path(game), :params => { :text => valid_text }
      end.not_to change(Level, :count)
    end

    it "shows each question and its correct option" do
      sign_in(author)

      post game_quiz_import_path(game), :params => { :text => valid_text }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Раз?")
      expect(response.body).to include("Да")
    end

    it "reports duplicates the game already has" do
      create_level(:game => game, :name => "Вопрос 1", :text => "Раз?")
      sign_in(author)

      post game_quiz_import_path(game), :params => { :text => valid_text }

      expect(response.body).to include(I18n.t("quiz_imports.preview.skipped"))
    end
  end

  describe "confirming" do
    it "creates the levels and redirects to the game" do
      sign_in(author)

      expect do
        post game_quiz_import_path(game), :params => { :text => valid_text, :confirm => "1" }
      end.to change(Level, :count).by(2)

      expect(response).to redirect_to(game_path(game))
    end

    it "skips questions the game already has" do
      create_level(:game => game, :name => "Вопрос 1", :text => "Раз?")
      sign_in(author)

      expect do
        post game_quiz_import_path(game), :params => { :text => valid_text, :confirm => "1" }
      end.to change(Level, :count).by(1)
    end
  end

  describe "malformed text" do
    it "re-renders with the parse errors" do
      sign_in(author)

      post game_quiz_import_path(game), :params => { :text => "Вопрос?\nA) Раз\nB) Два\n" }

      # 422, matching how every other form in this app re-renders after a
      # failed submission (QuestionsController, LevelsController).
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("quiz_imports.errors.no_correct_option", :line => 1))
    end

    # Separate from the message: RSpec fails fast, so a "creates nothing"
    # assertion after a body check could never fail on its own.
    it "creates nothing" do
      sign_in(author)

      expect do
        post game_quiz_import_path(game),
             :params => { :text => "Вопрос?\nA) Раз\nB) Два\n", :confirm => "1" }
      end.not_to change(Level, :count)
    end
  end

  # An author cannot add a level to a started game, so they cannot bulk-import
  # into one either.
  describe "a game that has already started" do
    it "refuses" do
      started = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      sign_in(author)

      get new_game_quiz_import_path(started)

      expect(response).to have_http_status(:unauthorized)
    end

    it "creates nothing when posted to" do
      started = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      sign_in(author)

      expect do
        post game_quiz_import_path(started), :params => { :text => valid_text, :confirm => "1" }
      end.not_to change(Level, :count)
    end
  end
end
