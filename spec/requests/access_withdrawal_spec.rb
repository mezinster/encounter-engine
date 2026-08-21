# -*- encoding : utf-8 -*-
require "rails_helper"

# The operator's end of it, over HTTP, through the form they actually use --
# and the customer's end, which is the point: the model examples prove the
# conversion is refused, and these prove that the refusal is what keeps a
# paying team playing.
describe "stopping the sale of access to a game", type: :request do
  let(:operator) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:captain)  { create_user }
  let(:team)     { create_team(:captain => captain) }
  let(:level)    { create_level }
  let(:game) do
    g = level.game
    g.update!(:author => operator, :visibility => "listed", :access_mode => "pass_required")
    set_game_schedule!(g, :starts_at => 3.days.from_now)
    g.reload
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Exactly what games/edit submits: the schedule fields ride along with the
  # dropdown whether or not the operator touched them.
  def convert_to_scheduled
    patch game_path(game), :params => { :game => {
      :name => game.name, :description => game.description,
      :max_team_number => game.max_team_number,
      :starts_at => 3.days.from_now.strftime("%Y-%m-%d %H:%M"),
      :access_mode => "scheduled"
    } }
  end

  it "refuses, and tells the operator what stands in the way" do
    create_access_pass(:game => game, :team => team)
    sign_in(operator)

    convert_to_scheduled

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Game.find(game.id).access_mode).to eq("pass_required")
    expect(response.body).to include(I18n.t("activerecord.attributes.game.access_mode"))
    expect(response.body).to include(
      I18n.t("activerecord.errors.models.game.attributes.access_mode.access_still_owed", :count => 1)
    )
  end

  # The whole reason the refusal exists. Before it, this team's access
  # evaporated the moment the operator changed a dropdown -- and their pass
  # stayed live for ever, so nothing anywhere showed that it had.
  it "leaves the paying team able to play" do
    create_access_pass(:game => game, :team => team)
    sign_in(operator)
    convert_to_scheduled
    reset!

    sign_in(captain)
    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
  end

  it "goes through once the outstanding access is revoked" do
    pass = create_access_pass(:game => game, :team => team)
    pass.update!(:revoked_at => Time.now)
    sign_in(operator)

    convert_to_scheduled

    expect(response).to have_http_status(:found)
    expect(Game.find(game.id).access_mode).to eq("scheduled")
  end

  it "goes through on a game that never sold any access" do
    game
    sign_in(operator)

    convert_to_scheduled

    expect(response).to have_http_status(:found)
    expect(Game.find(game.id).access_mode).to eq("scheduled")
  end
end
