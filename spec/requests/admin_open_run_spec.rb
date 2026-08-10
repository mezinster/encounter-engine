# -*- encoding : utf-8 -*-
require "rails_helper"

# Opening a run is the console's second non-index action, alongside set_author.
describe "opening a run as an operator", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def valid_params
    { :starts_at => 2.years.from_now.strftime("%Y-%m-%d %H:%M"),
      :registration_deadline => 23.months.from_now.strftime("%Y-%m-%d %H:%M"),
      :max_team_number => "10" }
  end

  it "opens the next run and says so" do
    sign_in(operator)

    expect {
      post open_run_admin_game_path(game), :params => valid_params
    }.to change { game.runs.reload.count }.by(1)

    expect(game.reload.current_run.ordinal).to eq(2)
    expect(response).to redirect_to(admin_games_path)
    expect(flash[:notice]).to eq(I18n.t("admin.games.run_opened", :ordinal => 2))
  end

  it "refuses while the current run is unfinished" do
    unfinished = create_game(:author => author, :is_draft => false)
    create_level(:game => unfinished)
    sign_in(operator)

    expect {
      post open_run_admin_game_path(unfinished), :params => valid_params
    }.not_to change { unfinished.runs.reload.count }

    expect(flash[:alert]).to eq(I18n.t("admin.games.cannot_open_unfinished"))
  end

  it "refuses a game with no levels" do
    empty = create_game(:author => author, :is_draft => false)
    set_game_schedule!(empty, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    sign_in(operator)

    expect {
      post open_run_admin_game_path(empty), :params => valid_params
    }.not_to change { empty.runs.reload.count }

    expect(flash[:alert]).to eq(I18n.t("admin.games.cannot_open_without_levels"))
  end

  it "refuses an invalid schedule, reporting why" do
    sign_in(operator)

    expect {
      post open_run_admin_game_path(game),
           :params => valid_params.merge(:starts_at => 1.hour.ago.strftime("%Y-%m-%d %H:%M"))
    }.not_to change { game.runs.reload.count }

    expect(flash[:alert]).to be_present
  end

  it "refuses a player who is not a superadmin" do
    sign_in(author)

    expect {
      post open_run_admin_game_path(game), :params => valid_params
    }.not_to change { game.runs.reload.count }

    expect(response).to have_http_status(:unauthorized)
  end

  # Game#status reads the current run, so opening one takes a finished game
  # back to :scheduled -- it reappears in the public list and leaves
  # «Завершённые игры». That is correct (it is open for registration again),
  # and it is asserted rather than assumed because several listings key off it.
  it "puts the game back on the schedule" do
    expect(game.status).to eq(:finished)
    sign_in(operator)

    post open_run_admin_game_path(game), :params => valid_params

    expect(game.reload.status).to eq(:scheduled)
  end

  # The other half of the same fact: opening a run makes started? false, which
  # re-opens content editing. Recorded in spec §6 as a deliberate consequence
  # rather than a bug, and pinned here so a later change cannot quietly
  # reverse it without someone noticing.
  it "re-opens content editing for the author" do
    sign_in(operator)
    post open_run_admin_game_path(game), :params => valid_params

    sign_in(author)
    get edit_game_path(game)

    expect(response).to have_http_status(:ok)
  end

  describe "auditing" do
    it "records the ordinal it opened" do
      sign_in(operator)

      expect {
        post open_run_admin_game_path(game), :params => valid_params
      }.to change(AdminAction, :count).by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("open_run")
      expect(entry.target_type).to eq("Game")
      expect(entry.details).to eq("2")
    end

    it "writes nothing for a refused open" do
      unfinished = create_game(:author => author, :is_draft => false)
      create_level(:game => unfinished)
      sign_in(operator)

      expect {
        post open_run_admin_game_path(unfinished), :params => valid_params
      }.not_to change(AdminAction, :count)
    end

    # The audit view falls back to the raw action name on a missing key, so
    # only asserting the identifier is ABSENT catches a forgotten label.
    it "renders a sentence in the log, not the raw action name" do
      sign_in(operator)
      post open_run_admin_game_path(game), :params => valid_params

      get admin_audit_index_path

      expect(response.body).to include(I18n.t("admin.audit.index.action.open_run"))
      expect(response.body).not_to include("open_run")
    end
  end

  it "offers the form on the console" do
    listed = game
    sign_in(operator)

    get admin_games_path

    expect(response.body).to include(open_run_admin_game_path(listed))
  end
end
