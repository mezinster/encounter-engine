require "rails_helper"

# Finding 3 of the whole-branch review, driven over HTTP through all three
# call sites at once: GamePassingsController#gated_passing,
# LogsController#gated_passing_for (via show_full_log) and
# InterventionsController#find_game_passing (via reinstate) each used to
# invent their own resolution of "this team's gated attempt", and could
# disagree once a team held two -- under SQLite, the unordered form picked
# the OLDEST, completed one. All three now defer to
# GamePassing.gated_attempt_for, and this proves they agree: given a team
# with an old, finished attempt and a newer, finished attempt, every site
# below acts on the NEWER one.
describe "resolving a team's gated attempt across every call site", type: :request do
  let(:level)      { create_level }
  let(:game) do
    g = level.game
    g.update!(:access_mode => "pass_required", :visibility => "listed")
    set_game_schedule!(g, :starts_at => 1.hour.ago)
    g
  end
  let(:captain)    { create_user }
  let(:team)       { create_team(:captain => captain) }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  let!(:old_pass) { create_access_pass(:game => game, :team => team) }
  let!(:old_attempt) do
    create_game_passing(:game => game, :team => team, :level => level,
                        :game_run => nil, :access_pass => old_pass)
  end

  let!(:new_pass) { create_access_pass(:game => game, :team => team) }
  let!(:new_attempt) do
    create_game_passing(:game => game, :team => team, :level => level,
                        :game_run => nil, :access_pass => new_pass)
  end

  before do
    old_attempt.update!(:finished_at => 3.days.ago)
    new_attempt.update!(:finished_at => 1.hour.ago)
    Log.create!(:game => game, :game_passing_id => old_attempt.id, :team => team.name, :team_id => team.id,
               :level => level.name, :level_id => level.id, :time => 3.days.ago, :answer => "old-code")
    Log.create!(:game => game, :game_passing_id => new_attempt.id, :team => team.name, :team_id => team.id,
               :level => level.name, :level_id => level.id, :time => 1.hour.ago, :answer => "new-code")
  end

  it "shows the newer attempt's own answers on the full log, not the older one's" do
    sign_in(captain)

    get show_full_log_path(:game_id => game.id)

    expect(response.body).to include("new-code")
    expect(response.body).not_to include("old-code")
  end

  it "reinstates the newer attempt, leaving the older one alone" do
    sign_in(superadmin)

    post reinstate_team_path(:game_id => game.id, :team_id => team.id)

    expect(new_attempt.reload.finished_at).to be_nil
    expect(old_attempt.reload.finished_at).to be_present
  end

  it "resumes the newer attempt to play once reinstated, rather than creating a third" do
    new_attempt.reinstate!
    sign_in(captain)

    expect {
      get show_current_level_path(:game_id => game.id)
    }.not_to change { GamePassing.count }

    expect(response).to have_http_status(:ok)
    expect(GamePassing.find_by(:access_pass_id => new_pass.id)).to eq(new_attempt)
  end
end
