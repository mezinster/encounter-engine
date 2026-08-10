# -*- encoding : utf-8 -*-
require "rails_helper"

# An author hands a game to another player. Mirrors TeamsController#hand_over,
# including its asymmetry: the author waits for the race to end, the operator
# does not.
describe "handing a game over to another author", type: :request do
  let(:author)    { create_user }
  let(:successor) { create_user }
  let(:game)      { create_game(:author => author) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def superadmin
    user = create_user
    user.update!(:is_superadmin => true)
    user
  end

  describe "the author" do
    it "transfers the game and says who now owns it" do
      sign_in(author)

      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(game.reload.author_id).to eq(successor.id)
      expect(flash[:notice]).to eq(I18n.t("games.hand_over.done", :nickname => successor.nickname))
    end

    # The redirect target is the games LIST, not the game, and deliberately:
    # a draft game is behind ensure_author_if_game_is_draft, so sending the
    # former author back to a game they no longer author would answer their
    # successful transfer with 401.
    it "redirects somewhere the former author can still reach" do
      draft = create_game(:author => author, :is_draft => true)
      sign_in(author)

      post hand_over_game_path(draft), :params => { :nickname => successor.nickname }

      expect(response).to redirect_to(games_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "loses access to the game it just gave away" do
      sign_in(author)
      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      get edit_game_path(game)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "refusals" do
    before { sign_in(author) }

    it "refuses a nickname nobody has, without saying so specifically" do
      post hand_over_game_path(game), :params => { :nickname => "нет-такого" }

      expect(game.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.unknown_user"))
    end

    # The same message as an unknown nickname, so the field cannot be used to
    # find out which nicknames exist.
    it "refuses a transfer to yourself with the same message" do
      post hand_over_game_path(game), :params => { :nickname => author.nickname }

      expect(game.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.unknown_user"))
    end

    # The lock means "under investigation". Letting its author pass the game to
    # a clean account is an escape hatch from the lock.
    it "refuses while editing is locked" do
      game.lock_editing!

      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(game.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.locked"))
    end

    it "refuses while the game is running" do
      running = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)

      post hand_over_game_path(running), :params => { :nickname => successor.nickname }

      expect(running.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.running"))
    end

    # A finished game IS transferable -- author_finished? clears the running
    # refusal, which is why the condition is not simply started?.
    it "allows a finished game" do
      finished = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      finished.update_column(:author_finished_at, Time.now)

      post hand_over_game_path(finished), :params => { :nickname => successor.nickname }

      expect(finished.reload.author_id).to eq(successor.id)
    end
  end

  describe "who may call it at all" do
    it "refuses a player who is not the author" do
      sign_in(create_user)

      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(response).to have_http_status(:unauthorized)
      expect(game.reload.author_id).to eq(author.id)
    end

    # Sent to log in, not answered with a bare 401. GamesController runs
    # require_authentication! (which raises Unauthenticated -> redirect),
    # unlike QuizImportsController, where ensure_author is the only guard and
    # a guest therefore gets 401. Both are correct; they are different
    # controllers with different filter chains.
    it "sends a guest to log in, changing nothing" do
      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(response).to redirect_to(login_path)
      expect(game.reload.author_id).to eq(author.id)
    end

    # ensure_author admits superadmins, and B-D3 gives them no lifecycle
    # refusals -- so the two guards above are the AUTHOR's, not everyone's.
    it "lets a superadmin transfer a running game through this same action" do
      running = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      sign_in(superadmin)

      post hand_over_game_path(running), :params => { :nickname => successor.nickname }

      expect(running.reload.author_id).to eq(successor.id)
    end
  end

  describe "auditing" do
    it "records nothing when the author acts on their own game" do
      sign_in(author)

      expect do
        post hand_over_game_path(game), :params => { :nickname => successor.nickname }
      end.not_to change(AdminAction, :count)
    end

    it "records an operator acting on someone else's game, naming both sides" do
      operator = superadmin
      sign_in(operator)

      expect do
        post hand_over_game_path(game), :params => { :nickname => successor.nickname }
      end.to change(AdminAction, :count).by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("hand_over_authorship")
      expect(entry.target_type).to eq("Game")
      expect(entry.details).to eq("#{author.nickname} -> #{successor.nickname}")
    end

    # The audit view renders the action through
    # t("admin.audit.index.action.#{entry.action}", :default => entry.action).
    # That :default keeps an unanticipated action from 500ing the log, at the
    # cost of a MISSING label failing nowhere and rendering as its own
    # identifier -- which is what shipped for six earlier actions until
    # 5d5fefb went back and fixed them. Asserting the identifier is ABSENT is
    # the only way to catch it; asserting the label is present would pass on
    # the fallback too if the two ever coincided.
    it "renders a sentence in the log, not the raw action name" do
      operator = superadmin
      sign_in(operator)
      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      get admin_audit_index_path

      expect(response.body).to include(I18n.t("admin.audit.index.action.hand_over_authorship"))
      expect(response.body).not_to include("hand_over_authorship")
    end
  end
end
