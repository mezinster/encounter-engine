require "rails_helper"

describe "withdrawing a game through the form", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def superadmin
    user = create_user
    user.update!(:is_superadmin => true)
    user
  end

  def running_game
    game = create_game
    create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    game.reload
  end

  it "shows the form" do
    game = running_game
    sign_in(superadmin)

    get new_withdrawal_game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("games.withdrawal.categories.technical"))
    expect(response.body).to include(I18n.t("games.withdrawal.form.mode_freeze"))
  end

  it "withdraws with the category, note and mode it was given" do
    game = running_game
    admin = superadmin
    sign_in(admin)

    post withdraw_game_path(game), :params => { :withdrawal_category => "technical",
                                                :withdrawal_note => "Код на точке 4 неверный",
                                                :withdrawal_mode => "freeze" }

    game.reload
    expect(game.withdrawn?).to be true
    expect(game.withdrawal_category).to eq("technical")
    expect(game.withdrawal_note).to eq("Код на точке 4 неверный")
    expect(game.withdrawal_mode).to eq("freeze")
  end

  it "records the category, note and mode in the audit" do
    game = running_game
    sign_in(superadmin)

    post withdraw_game_path(game), :params => { :withdrawal_category => "weather",
                                                :withdrawal_note => "Гроза",
                                                :withdrawal_mode => "ended" }

    entry = AdminAction.where(:action => "withdraw").last
    expect(entry.details).to include("weather")
    expect(entry.details).to include("ended")
    expect(entry.details).to include("Гроза")
  end

  it "refuses a missing category and withdraws nothing" do
    game = running_game
    sign_in(superadmin)

    post withdraw_game_path(game), :params => { :withdrawal_mode => "freeze" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(game.reload.withdrawn?).to be false
  end

  it "refuses an ordinary user" do
    game = running_game
    sign_in(create_user)

    post withdraw_game_path(game), :params => { :withdrawal_category => "technical",
                                                :withdrawal_mode => "freeze" }

    expect(response).to have_http_status(:unauthorized)
    expect(game.reload.withdrawn?).to be false
  end

  it "still refuses an operator intervention while the game is withdrawn" do
    game = running_game
    passing = create_game_passing(:level => game.levels.first)
    author = game.author
    game.withdraw!(:category => "technical", :mode => "freeze")
    sign_in(author)

    post reinstate_team_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).not_to have_http_status(:ok)
    expect(passing.reload.status).to be_nil
  end
end
