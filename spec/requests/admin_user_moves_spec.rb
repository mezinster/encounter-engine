require "rails_helper"

# S2 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md:
# a superadmin moves a user between teams without their consent. The move
# itself is one column write; every refusal below is the actual feature.
describe "moving a user between teams", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). create_user sets the
  # password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # create_team makes its captain a member via adopt_captain, so a team built
  # with a separate captain has exactly one movable plain member.
  def team_with_member
    captain = create_user
    team = create_team(:captain => captain)
    member = create_user
    team.members << member
    [team, member]
  end

  it "moves a plain member to another team and records an audit entry" do
    _source, member = team_with_member
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(destination)
    expect(response).to redirect_to(admin_user_path(member))
    action = AdminAction.order(:id).last
    expect(action.action).to eq("move_user")
    expect(action.target_id).to eq(member.id)
  end

  # Deliberately allowed: there is no source team to disturb, and this is how
  # an operator places someone who has no team.
  it "places a teamless user into a team" do
    stray = create_user
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(stray), :params => { :team_id => destination.id }

    expect(stray.reload.team).to eq(destination)
  end

  # Refusal 1: moving a captain would leave their team captainless -- the
  # bricked state this programme exists to remove -- and would put
  # users.team_id and teams.captain_id in disagreement.
  it "refuses to move a captain" do
    captain = create_user
    create_team(:captain => captain)
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(captain), :params => { :team_id => destination.id }

    expect(flash[:alert]).to eq(I18n.t("admin.users.cannot_move_captain"))
  end

  # The data property, separate from the message above: RSpec fails fast, so
  # an assertion after the flash check could never fail on its own. Both
  # earlier phases found one of their own security assertions decorative that
  # way.
  it "leaves a captain's team and captaincy intact when the move is refused" do
    captain = create_user
    source = create_team(:captain => captain)
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(captain), :params => { :team_id => destination.id }

    expect(captain.reload.team).to eq(source)
    expect(source.reload.captain).to eq(captain)
  end

  # Refusal 2: joining a run already under way hands the newcomer levels
  # their teammates solved.
  it "refuses to move anyone into a team that is mid-race" do
    source, member = team_with_member
    destination = create_team(:captain => create_user)
    create_game_passing(:team => destination, :level => create_level)
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
  end

  # Refusal 3: removing a player mid-run changes a racing team's composition
  # without its captain knowing. D1 -- consent-free moves wait for the race.
  it "refuses to move anyone out of a team that is mid-race" do
    source, member = team_with_member
    create_game_passing(:team => source, :level => create_level)
    destination = create_team(:captain => create_user)
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
  end

  # Refusal 4: nothing to do, and an audit entry for a move that did not
  # happen is worse than no entry.
  it "refuses a move into the team the user is already in" do
    source, member = team_with_member
    sign_in(superadmin)

    expect do
      post move_admin_user_path(member), :params => { :team_id => source.id }
    end.not_to change(AdminAction, :count)

    expect(member.reload.team).to eq(source)
  end

  it "refuses an unknown destination team" do
    source, member = team_with_member
    sign_in(superadmin)

    post move_admin_user_path(member), :params => { :team_id => 0 }

    expect(member.reload.team).to eq(source)
  end

  it "refuses an ordinary signed-in user" do
    source, member = team_with_member
    destination = create_team(:captain => create_user)
    sign_in(create_user)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an anonymous visitor" do
    source, member = team_with_member
    destination = create_team(:captain => create_user)

    post move_admin_user_path(member), :params => { :team_id => destination.id }

    expect(member.reload.team).to eq(source)
    expect(response).to redirect_to(login_path)
  end
end
