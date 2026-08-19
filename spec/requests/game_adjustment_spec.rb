require "rails_helper"

describe "an operator adjusting a team's points for one game", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def live_game_with_passing(attrs = {})
    author  = attrs[:author] || create_user
    game    = create_game(:author => author)
    level   = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    passing = create_game_passing(:level => level)
    [ author, game, passing ]
  end

  it "shows a form, then a confirmation, then writes on the confirmed post" do
    author, game, passing = live_game_with_passing
    sign_in(author)

    get new_team_adjustment_path(:game_id => game.id, :team_id => passing.team_id)
    expect(response).to have_http_status(:ok)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "Пропустили точку" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("-50")
    expect(response.body).to include("Пропустили точку")
    expect(PointTransaction.where(:reason => "adjustment").count).to eq(0)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "Пропустили точку", :confirmed => "1" }

    row = PointTransaction.find_by(:reason => "adjustment")
    expect(row.amount).to eq(-50)
    expect(row.note).to eq("Пропустили точку")
    expect(row.game_passing_id).to eq(passing.id)
    expect(row.created_by_id).to eq(author.id)
  end

  # A7. This is the example the whole task turns on.
  it "adjusts a FINISHED run" do
    author, game, passing = live_game_with_passing
    passing.update!(:finished_at => 1.hour.ago)
    sign_in(author)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => 30, :note => "Точка была закрыта", :confirmed => "1" }

    expect(PointTransaction.where(:reason => "adjustment").count).to eq(1)
  end

  it "adjusts an EXITED run" do
    author, game, passing = live_game_with_passing
    passing.exit!
    sign_in(author)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => 30, :note => "Компенсация", :confirmed => "1" }

    expect(PointTransaction.where(:reason => "adjustment").count).to eq(1)
  end

  it "refuses a blank note without writing anything" do
    author, game, passing = live_game_with_passing
    sign_in(author)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "", :confirmed => "1" }

    expect(PointTransaction.where(:reason => "adjustment").count).to eq(0)
  end

  it "refuses an ordinary user" do
    _author, game, passing = live_game_with_passing
    sign_in(create_user)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "x", :confirmed => "1" }

    expect(PointTransaction.where(:reason => "adjustment").count).to eq(0)
  end
end
