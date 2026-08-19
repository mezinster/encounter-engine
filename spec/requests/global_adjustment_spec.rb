require "rails_helper"

describe "a superadmin adjusting a team's points globally", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def superadmin
    user = create_user
    user.update!(:is_superadmin => true)
    user
  end

  it "writes a row belonging to no game" do
    team = create_team(:captain => create_user)
    admin = superadmin
    sign_in(admin)

    post admin_team_adjustments_path(:team_id => team.id),
         :params => { :amount => -25, :note => "Нарушение регламента", :confirmed => "1" }

    row = PointTransaction.find_by(:reason => "adjustment")
    expect(row.team_id).to eq(team.id)
    expect(row.game_id).to be_nil
    expect(row.game_passing_id).to be_nil
    expect(row.created_by_id).to eq(admin.id)
    expect(team.balance).to eq(-25)
  end

  it "confirms before writing" do
    team = create_team(:captain => create_user)
    sign_in(superadmin)

    post admin_team_adjustments_path(:team_id => team.id),
         :params => { :amount => -25, :note => "Нарушение регламента" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(team.name)
    expect(PointTransaction.count).to eq(0)
  end

  it "refuses an operator" do
    team = create_team(:captain => create_user)
    operator = create_user
    operator.update!(:is_operator => true)
    sign_in(operator)

    post admin_team_adjustments_path(:team_id => team.id),
         :params => { :amount => -25, :note => "x", :confirmed => "1" }

    expect(response).to have_http_status(:unauthorized)
    expect(PointTransaction.count).to eq(0)
  end

  it "refuses a signed-out visitor" do
    team = create_team(:captain => create_user)

    post admin_team_adjustments_path(:team_id => team.id),
         :params => { :amount => -25, :note => "x", :confirmed => "1" }

    expect(response).to redirect_to(login_path)
    expect(PointTransaction.count).to eq(0)
  end
end
