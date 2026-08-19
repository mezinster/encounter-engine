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

  # Spec A4's line: an author DOES have authority to adjust a team on their
  # OWN game (Task 2, InterventionsController#create_adjustment) but must NOT
  # have it here, because a global row has no game to scope it to and reaches
  # every game the team has ever played -- including games this author has
  # nothing to do with. That asymmetry is why this controller is
  # superadmin-only rather than another action riding ensure_author. The
  # author here genuinely owns a game, so this exercises that authority
  # boundary rather than standing in for "any non-superadmin".
  it "refuses a game author" do
    team = create_team(:captain => create_user)
    author = create_user
    create_game(:author => author)
    sign_in(author)

    post admin_team_adjustments_path(:team_id => team.id),
         :params => { :amount => -25, :note => "x", :confirmed => "1" }

    expect(response).to have_http_status(:unauthorized)
    expect(PointTransaction.count).to eq(0)
  end

  it "refuses an ordinary signed-in user" do
    team = create_team(:captain => create_user)
    sign_in(create_user)

    post admin_team_adjustments_path(:team_id => team.id),
         :params => { :amount => -25, :note => "x", :confirmed => "1" }

    expect(response).to have_http_status(:unauthorized)
    expect(PointTransaction.count).to eq(0)
  end

  # Spec section 4.4 wants the actor, the team, the amount AND the note. This
  # path always recorded, but with `details` left nil -- so an investigator
  # learnt that a team had been adjusted globally and neither by how much nor
  # why, on the door with the widest blast radius of the two. F3 of the
  # whole-branch review.
  #
  # The team is named in `details` even though target_label already carries it:
  # the two doors then read identically in the log's details column, which is
  # the only column an investigator can compare across them.
  it "audits the adjustment with the team, the amount and the note" do
    team  = create_team(:captain => create_user)
    admin = superadmin
    sign_in(admin)

    expect {
      post admin_team_adjustments_path(:team_id => team.id),
           :params => { :amount => -25, :note => "Нарушение регламента", :confirmed => "1" }
    }.to change { AdminAction.count }.by(1)

    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("adjust_points_globally")
    expect(entry.actor_id).to eq(admin.id)
    expect(entry.target_type).to eq("Team")
    expect(entry.target_id).to eq(team.id)
    expect(entry.details).to include(team.name)
    expect(entry.details).to include("-25")
    expect(entry.details).to include("Нарушение регламента")
  end

  # After the row lands, never before -- AdminAudit's own rule.
  it "records nothing when the adjustment is refused" do
    team = create_team(:captain => create_user)
    sign_in(superadmin)

    expect {
      post admin_team_adjustments_path(:team_id => team.id),
           :params => { :amount => 0, :note => "x", :confirmed => "1" }
    }.not_to change { AdminAction.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(PointTransaction.count).to eq(0)
  end
end
