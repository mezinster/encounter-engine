require "rails_helper"

describe "issuing and revoking access passes", type: :request do
  let(:level)      { create_level }
  let(:game)       { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }
  let(:operator)   { u = create_user; u.update!(:is_operator => true); u }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:ordinary)   { create_user }
  let(:team)       { create_team }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary signed-in user" do
    sign_in(ordinary)
    post game_access_passes_path(game), :params => { :team_name => team.name }
    expect(response).to have_http_status(:unauthorized)
    expect(AccessPass.count).to eq(0)
  end

  it "refuses an anonymous visitor" do
    post game_access_passes_path(game), :params => { :team_name => team.name }
    expect(AccessPass.count).to eq(0)
  end

  it "lets an operator issue a pass" do
    sign_in(operator)
    expect { post game_access_passes_path(game), :params => { :team_name => team.name } }
      .to change { AccessPass.count }.by(1)

    pass = AccessPass.last
    expect(pass.team_id).to eq(team.id)
    expect(pass.game_id).to eq(game.id)
    expect(pass.source).to eq("operator_invite")
    expect(pass.issued_by_id).to eq(operator.id)
  end

  it "lets a superadmin issue a pass" do
    sign_in(superadmin)
    expect { post game_access_passes_path(game), :params => { :team_name => team.name } }
      .to change { AccessPass.count }.by(1)
  end

  it "records an audit entry" do
    sign_in(operator)
    expect { post game_access_passes_path(game), :params => { :team_name => team.name } }
      .to change { AdminAction.count }.by(1)
    expect(AdminAction.newest_first.first.action).to eq("issue_access_pass")
  end

  it "reports an unknown team without creating anything" do
    sign_in(operator)
    expect { post game_access_passes_path(game), :params => { :team_name => "no such team" } }
      .not_to change { AccessPass.count }
    expect(response).to redirect_to(game_access_passes_path(game))
  end

  it "refuses to issue on a scheduled game" do
    scheduled = create_level.game
    sign_in(operator)
    post game_access_passes_path(scheduled), :params => { :team_name => team.name }
    expect(AccessPass.count).to eq(0)
  end

  it "revokes an unused pass" do
    pass = create_access_pass(:game => game, :team => team)
    sign_in(operator)

    delete game_access_pass_path(game, pass)

    expect(pass.reload.revoked_at).to be_present
    expect(AdminAction.newest_first.first.action).to eq("revoke_access_pass")
  end

  # B11: a started run is an intervention problem, not a revocation one.
  it "refuses to revoke a pass whose attempt has begun" do
    pass = create_access_pass(:game => game, :team => team)
    create_game_passing(:game => game, :team => team, :level => level,
                        :game_run => nil, :access_pass => pass)
    sign_in(operator)

    delete game_access_pass_path(game, pass)

    expect(pass.reload.revoked_at).to be_nil
  end
end
