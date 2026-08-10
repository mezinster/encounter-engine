# -*- encoding : utf-8 -*-
require "rails_helper"

# Admission belongs to a run. Every example builds a second run, because with
# one run a run-scoped entry query returns exactly what the game-scoped one
# returned and would pass either way.
describe "entries scoped to a run", type: :request do
  let(:author)  { create_user }
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }
  let(:game) do
    g = create_game(:author => author, :is_draft => false, :max_team_number => 10)
    create_level(:game => g)
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def second_run(g)
    g.open_run!(:starts_at => 2.years.from_now,
                :registration_deadline => 23.months.from_now,
                :max_team_number => 10)
    g.reload
  end

  # THE blocker. Run 1's entries stay "accepted" for ever, and the old unique
  # index was on (team_id, game_id) for live statuses -- so this application
  # was refused by the database with an opaque uniqueness error.
  it "lets a team accepted in run 1 apply to run 2" do
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => team, :status => "accepted")
    second_run(game)
    captain.reload
    sign_in(captain)

    expect {
      post new_game_entry_path(:game_id => game.id, :team_id => team.id)
    }.to change { GameEntry.where(:game_run_id => game.current_run.id).count }.by(1)
  end

  it "does not let a team play run 2 on its run 1 acceptance alone" do
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => team, :status => "accepted")
    second_run(game)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    captain.reload
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
  end

  it "lets it play run 2 once it is accepted there" do
    second_run(game)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => team, :status => "accepted")
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    captain.reload
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
  end

  it "counts a new run's capacity from zero" do
    game.current_run.update_column(:requested_teams_number, 9)
    run_two = second_run(game).current_run

    expect(run_two.requested_teams_number).to eq(0)
  end

  # The author's pending list belongs to the run being registered for.
  it "shows the author only the current run's pending entries" do
    old_team = create_team(:captain => create_user)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => old_team, :status => "new")
    second_run(game)
    new_team = create_team(:captain => create_user)
    GameEntry.create!(:game => game, :game_run => game.current_run,
                      :team => new_team, :status => "new")
    sign_in(author)

    get game_path(game)

    expect(response.body).to include(new_team.name)
    expect(response.body).not_to include(old_team.name)
  end
end
