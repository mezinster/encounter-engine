# -*- encoding : utf-8 -*-
require "rails_helper"

# The operator's override. Mirrors Admin::TeamsController#set_captain: the same
# model method as the author's own path, no lifecycle refusals, always audited.
describe "reassigning a game's author as an operator", type: :request do
  let(:author)    { create_user }
  let(:successor) { create_user }
  let(:game)      { create_game(:author => author) }
  let(:operator)  { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "reassigns the author and says who it now is" do
    sign_in(operator)

    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(game.reload.author_id).to eq(successor.id)
    expect(response).to redirect_to(admin_games_path)
    expect(flash[:notice]).to eq(I18n.t("admin.games.author_set", :nickname => successor.nickname))
  end

  # No lifecycle refusals at all, deliberately -- the same exemption
  # Team#in_live_race? documents for the superadmin captaincy path. This is the
  # example that would fail if transfer_authorship_to! used update! instead of
  # update_column.
  it "reassigns a running game" do
    running = create_game(:author => author, :starts_at => 1.minute.from_now)
    allow(Time).to receive(:now).and_return(1.hour.from_now)
    sign_in(operator)

    post set_author_admin_game_path(running), :params => { :nickname => successor.nickname }

    expect(running.reload.author_id).to eq(successor.id)
  end

  it "reassigns a game whose editing is locked" do
    game.lock_editing!
    sign_in(operator)

    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(game.reload.author_id).to eq(successor.id)
  end

  it "refuses a nickname nobody has, changing nothing" do
    sign_in(operator)

    post set_author_admin_game_path(game), :params => { :nickname => "нет-такого" }

    expect(game.reload.author_id).to eq(author.id)
    expect(flash[:alert]).to eq(I18n.t("admin.games.no_such_user"))
  end

  # Refused before anything changes, matching Admin::UsersController#revoke, so
  # the log never holds an entry for a change that did not happen.
  it "writes no audit entry for a refused reassignment" do
    sign_in(operator)

    expect do
      post set_author_admin_game_path(game), :params => { :nickname => "нет-такого" }
    end.not_to change(AdminAction, :count)
  end

  it "records the reassignment, naming both sides" do
    sign_in(operator)

    expect do
      post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }
    end.to change(AdminAction, :count).by(1)

    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("set_author")
    expect(entry.target_type).to eq("Game")
    expect(entry.target_id).to eq(game.id)
    expect(entry.details).to eq("#{author.nickname} -> #{successor.nickname}")
  end

  # Same guard as hand_over_authorship: the audit view falls back to the raw
  # action name on a missing key, so only asserting the identifier is ABSENT
  # catches a forgotten label.
  it "renders a sentence in the log, not the raw action name" do
    sign_in(operator)
    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    get admin_audit_index_path

    expect(response.body).to include(I18n.t("admin.audit.index.action.set_author"))
    expect(response.body).not_to include("set_author")
  end

  it "refuses a player who is not a superadmin" do
    sign_in(author)

    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(response).to have_http_status(:unauthorized)
    expect(game.reload.author_id).to eq(author.id)
  end

  # Sent to log in rather than answered with 401: Admin::GamesController runs
  # require_authentication! before require_superadmin!.
  it "sends a guest to log in, changing nothing" do
    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(response).to redirect_to(login_path)
    expect(game.reload.author_id).to eq(author.id)
  end

  it "offers the form on the console" do
    # game is a lazy let: referencing it only inside the expectation would
    # create it AFTER the page was rendered, and the console would have listed
    # an empty table.
    listed = game
    sign_in(operator)

    get admin_games_path

    expect(response.body).to include(set_author_admin_game_path(listed))
  end
end
