require "rails_helper"

describe "playing a game that has been withdrawn", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A real team with a captain, mid-run, on a started game.
  def team_mid_run
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:max_skips => 2)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    passing = create_game_passing(:level => one, :team => team)
    [ game.reload, passing, captain ]
  end

  it "shows the reason on the play screen instead of the level" do
    game, _passing, captain = team_mid_run
    game.withdraw!(:category => "technical", :note => "Код на точке 4 неверный",
                   :mode => "freeze")
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("games.withdrawal.categories.technical"))
    expect(response.body).to include("Код на точке 4 неверный")
  end

  it "refuses an answer, and the team lands on the explanation" do
    game, passing, captain = team_mid_run
    level_before = passing.current_level
    game.withdraw!(:category => "safety", :mode => "freeze")
    sign_in(captain)

    post post_answer_path(:game_id => game.id), :params => { :answer => "anything" }

    expect(response).to redirect_to(show_current_level_path(:game_id => game.id))
    expect(passing.reload.current_level).to eq(level_before)
  end

  it "refuses a skip" do
    game, passing, captain = team_mid_run
    game.withdraw!(:category => "weather", :mode => "freeze")
    sign_in(captain)

    post skip_level_path(:game_id => game.id)

    expect(response).to redirect_to(show_current_level_path(:game_id => game.id))
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  it "lets the team play again once the game is restored, on the level they were on" do
    game, passing, captain = team_mid_run
    level_before = passing.current_level
    game.withdraw!(:category => "technical", :mode => "freeze")
    game.restore!
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("games.withdrawal.categories.technical"))
    expect(passing.reload.current_level).to eq(level_before)
  end

  # The note is operator-authored free text on a page a team reads mid-race.
  it "escapes markup in the note" do
    game, _passing, captain = team_mid_run
    game.withdraw!(:category => "other", :note => "<script>alert(1)</script>",
                   :mode => "freeze")
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("<script>alert(1)</script>")
    expect(response.body).to include("&lt;script&gt;")
  end
end
