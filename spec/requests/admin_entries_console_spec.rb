# -*- encoding : utf-8 -*-
require "rails_helper"

# Opening a run is an operator power but populating it was not: accept is
# behind ensure_author (which admits superadmins) while games/show gates the
# entries block on author_of? (which does not), so the action was permitted
# and the button never rendered.
describe "the operator's entries console", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:team)     { create_team(:captain => create_user) }
  let(:game) do
    g = create_game(:author => author, :is_draft => false, :max_team_number => 10)
    create_level(:game => g)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def pending_entry(run = game.current_run)
    GameEntry.create!(:game => game, :game_run => run, :team => team, :status => "new")
  end

  it "lists the current run's pending teams" do
    pending_entry
    sign_in(operator)

    get admin_game_entries_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(team.name)
  end

  # Admission belongs to a run. An operator must not be shown an applicant to
  # a cohort that has already been and gone.
  it "does not list an earlier run's entries" do
    old_team = create_team(:captain => create_user)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => old_team, :status => "new")
    game.open_run!(:starts_at => 2.years.from_now,
                   :registration_deadline => 23.months.from_now,
                   :max_team_number => 10)
    game.reload
    pending_entry(game.current_run)
    sign_in(operator)

    get admin_game_entries_path(game)

    expect(response.body).to include(team.name)
    expect(response.body).not_to include(old_team.name)
  end

  it "accepts an application" do
    entry = pending_entry
    sign_in(operator)

    post accept_admin_game_entry_path(game, entry)

    expect(entry.reload.status).to eq("accepted")
    expect(response).to redirect_to(admin_game_entries_path(game))
  end

  it "rejects an application and frees its place" do
    entry = pending_entry
    game.current_run.update_column(:requested_teams_number, 1)
    sign_in(operator)

    post reject_admin_game_entry_path(game, entry)

    expect(entry.reload.status).to eq("rejected")
    expect(game.reload.requested_teams_number).to eq(0)
  end

  # THE production bug the guard exists for. Rejecting twice must not free a
  # second place: the counter would drift below what is actually taken and let
  # an extra team past max_team_number. Seen for real with a captain
  # double-clicking «Отозвать» -- see GameEntriesController#recall's comment.
  it "does not free a second place when rejected twice" do
    entry = pending_entry
    game.current_run.update_column(:requested_teams_number, 2)
    sign_in(operator)

    post reject_admin_game_entry_path(game, entry)
    post reject_admin_game_entry_path(game, entry)

    expect(game.reload.requested_teams_number).to eq(1)
  end

  it "refuses a player who is not a superadmin" do
    entry = pending_entry
    sign_in(author)

    post accept_admin_game_entry_path(game, entry)

    expect(response).to have_http_status(:unauthorized)
    expect(entry.reload.status).to eq("new")
  end

  # Scoped through the run, so an id belonging to another game or run 404s
  # rather than being acted on -- the same discipline as
  # Admin::TeamsController#set_captain looking members up through the team.
  it "404s on an entry from another game" do
    other = create_game(:author => author, :is_draft => false)
    stray = GameEntry.create!(:game => other, :game_run => other.current_run,
                              :team => team, :status => "new")
    sign_in(operator)

    expect {
      post accept_admin_game_entry_path(game, stray)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  describe "auditing" do
    it "records an acceptance against the game, naming the team" do
      entry = pending_entry
      sign_in(operator)

      expect { post accept_admin_game_entry_path(game, entry) }
        .to change(AdminAction, :count).by(1)

      row = AdminAction.newest_first.first
      expect(row.action).to eq("accept_entry")
      expect(row.target_type).to eq("Game")
      expect(row.details).to eq(team.name)
    end

    it "records a rejection" do
      entry = pending_entry
      sign_in(operator)

      post reject_admin_game_entry_path(game, entry)

      expect(AdminAction.newest_first.first.action).to eq("reject_entry")
    end

    it "writes nothing for a no-op second reject" do
      entry = pending_entry
      sign_in(operator)
      post reject_admin_game_entry_path(game, entry)

      expect { post reject_admin_game_entry_path(game, entry) }
        .not_to change(AdminAction, :count)
    end

    # The audit view falls back to the raw action name on a missing key, so
    # only asserting the identifier is ABSENT catches a forgotten label.
    it "renders sentences in the log, not raw action names" do
      entry = pending_entry
      sign_in(operator)
      post accept_admin_game_entry_path(game, entry)

      get admin_audit_index_path

      expect(response.body).to include(I18n.t("admin.audit.index.action.accept_entry"))
      expect(response.body).not_to include("accept_entry")
    end
  end
end
