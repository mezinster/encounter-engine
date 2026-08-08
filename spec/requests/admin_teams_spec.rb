require "rails_helper"

# The admin console had no team management at all before this --
# app/controllers/admin/ was audit, dashboard, games, users. See
# docs/superpowers/specs/2026-08-08-team-membership-programme-design.md, S1.
describe "the admin teams console", type: :request do
  let(:captain)    { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  # create_user sets the password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # An anonymous visitor hits require_authentication! before
  # require_superadmin! ever runs, so this is a redirect to login rather than
  # the 401 the signed-in-but-not-admin case gets -- same asymmetry
  # admin_console_spec documents.
  it "refuses an anonymous visitor" do
    get admin_teams_path
    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(login_path)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(create_user)
    get admin_teams_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "lists every team with its captain and members" do
    team = create_team(:captain => captain)
    member = create_user
    team.members << member
    sign_in(superadmin)

    get admin_teams_path

    expect(response.body).to include(team.name)
    expect(response.body).to include(captain.nickname)
    expect(response.body).to include(member.nickname)
  end

  # A captainless team is a valid state -- captain_id is nullable and Team
  # declares belongs_to :captain, optional: true -- and it is exactly the
  # state an operator opens this screen to repair, so it must render rather
  # than 500 on a nil dereference.
  it "renders a team that has no captain" do
    orphan = create_team
    sign_in(superadmin)

    get admin_teams_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(orphan.name)
    expect(response.body).to include(I18n.t("admin.teams.index.no_captain"))
  end

  describe "reassigning a captain" do
    it "moves captaincy to another member and records an audit entry" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor
      sign_in(superadmin)

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(successor)
      expect(response).to redirect_to(admin_teams_path)
      action = AdminAction.order(:id).last
      expect(action.action).to eq("set_captain")
      expect(action.target_id).to eq(team.id)
    end

    # The whole point of the screen: a team nobody can act on gets a captain
    # back. captain_id nil is the bricked state -- no invitations, no game
    # registration, no way to quit a race -- and this is its only exit.
    it "rescues a captainless team" do
      orphan = create_team
      member = create_user
      orphan.members << member
      sign_in(superadmin)

      post set_captain_admin_team_path(orphan), :params => { :member_id => member.id }

      expect(orphan.reload.captain).to eq(member)
    end

    # D1: the superadmin path is deliberately allowed mid-race, unlike the
    # captain's own handover. Pinned from this side so nobody later "fixes"
    # the asymmetry into consistency -- the abandoned-captain case is most
    # acute mid-race, because quitting is itself captain-only.
    it "is allowed while the team is in a live race" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor
      create_game_passing(:team => team, :level => create_level)
      sign_in(superadmin)

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(successor)
    end

    # The strict-scoping test. member_id is looked up THROUGH team.members, so
    # a crafted id belonging to somebody else's team is refused before it can
    # reach set_captain! -- and cannot be stolen out of their own team, which
    # is the failure mode Team's validation would otherwise have to catch
    # alone.
    it "refuses a member_id belonging to another team, changing nothing" do
      team = create_team(:captain => captain)
      outsider = create_user
      other_team = create_team(:captain => outsider)
      sign_in(superadmin)

      post set_captain_admin_team_path(team), :params => { :member_id => outsider.id }

      expect(team.reload.captain).to eq(captain)
      expect(outsider.reload.team).to eq(other_team)
      expect(other_team.reload.captain).to eq(outsider)
    end

    it "refuses an ordinary signed-in user" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor
      sign_in(create_user)

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(captain)
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses an anonymous visitor" do
      team = create_team(:captain => captain)
      successor = create_user
      team.members << successor

      post set_captain_admin_team_path(team), :params => { :member_id => successor.id }

      expect(team.reload.captain).to eq(captain)
      expect(response).to redirect_to(login_path)
    end
  end

  # N+1 guard, mirroring the one in admin_console_spec: the view renders the
  # captain and the member list per row, which without preloading is two
  # extra queries per team. Compares a small fixture against a larger one so
  # the assertion is about the SLOPE, not a magic number that any unrelated
  # query would break.
  it "keeps the query count flat as the number of teams grows" do
    sign_in(superadmin)
    2.times { create_team(:captain => create_user) }
    small = count_queries { get admin_teams_path }

    6.times { create_team(:captain => create_user) }
    large = count_queries { get admin_teams_path }

    expect(large).to be <= small + 1
  end
end
