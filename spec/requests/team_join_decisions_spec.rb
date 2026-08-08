require "rails_helper"

# The deciding half of S4: only the TARGET team's captain may accept or
# reject a request addressed to that team.
describe "deciding a join request", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before :each do
    @captain = create_user
    @team = create_team(:captain => @captain)
    @applicant = create_user
    @join_request = TeamJoinRequest.create!(:user => @applicant, :team => @team)
  end

  it "accepts, attaching the applicant to the team" do
    sign_in(@captain)

    post accept_join_request_path(@join_request)

    expect(@join_request.reload.status).to eq("accepted")
    expect(@applicant.reload.team).to eq(@team)
  end

  it "detaches the applicant from the team they were in" do
    source = create_team(:captain => create_user)
    source.members << @applicant
    sign_in(@captain)

    post accept_join_request_path(@join_request)

    expect(@applicant.reload.team).to eq(@team)
    expect(source.reload.members).not_to include(@applicant)
  end

  # Mirrors InvitationsController#reject_rest_of_invitations: an applicant who
  # has landed somewhere should not be left with live applications elsewhere,
  # which a captain would later accept into nothing.
  it "auto-rejects the applicant's other pending requests" do
    elsewhere = TeamJoinRequest.create!(:user => @applicant,
                                        :team => create_team(:captain => create_user))
    sign_in(@captain)

    post accept_join_request_path(@join_request)

    expect(elsewhere.reload.status).to eq("rejected")
  end

  it "rejects without moving anyone" do
    sign_in(@captain)

    post reject_join_request_path(@join_request)

    expect(@join_request.reload.status).to eq("rejected")
    expect(@applicant.reload.team).to be_nil
  end

  # THE guard. SecurityFilters#ensure_team_captain only asks "is this user *a*
  # captain" and derives the team from current_user, so it would let the
  # captain of another team decide this one's requests. Phase 2's mutation
  # proved that hole is real, not theoretical.
  it "refuses the captain of another team" do
    intruder = create_user
    create_team(:captain => intruder)
    sign_in(intruder.reload)

    post accept_join_request_path(@join_request)

    expect(response).to have_http_status(:unauthorized)
  end

  # The data property, separate from the status: RSpec fails fast.
  it "changes nothing when another team's captain tries to decide" do
    intruder = create_user
    create_team(:captain => intruder)
    sign_in(intruder.reload)

    post accept_join_request_path(@join_request) rescue nil

    expect(@join_request.reload.status).to eq("new")
    expect(@applicant.reload.team).to be_nil
  end

  it "refuses a plain member of the target team" do
    member = create_user
    @team.members << member
    sign_in(member.reload)

    post accept_join_request_path(@join_request) rescue nil

    expect(@join_request.reload.status).to eq("new")
  end

  it "refuses the applicant themselves" do
    sign_in(@applicant)

    post accept_join_request_path(@join_request) rescue nil

    expect(@join_request.reload.status).to eq("new")
    expect(@applicant.reload.team).to be_nil
  end

  it "refuses a guest" do
    post accept_join_request_path(@join_request)

    expect(@join_request.reload.status).to eq("new")
    expect(response).to redirect_to(login_path)
  end

  # D1, both ends. The applicant's team was checked when they applied, but
  # a race may have started since; the target's is checked here for the
  # first time.
  it "refuses while the target team is mid-race" do
    create_game_passing(:team => @team, :level => create_level)
    sign_in(@captain)

    post accept_join_request_path(@join_request)

    expect(@join_request.reload.status).to eq("new")
    expect(@applicant.reload.team).to be_nil
  end

  it "refuses while the applicant's current team is mid-race" do
    source = create_team(:captain => create_user)
    source.members << @applicant
    create_game_passing(:team => source, :level => create_level)
    sign_in(@captain)

    post accept_join_request_path(@join_request)

    expect(@join_request.reload.status).to eq("new")
    expect(@applicant.reload.team).to eq(source)
  end

  # They may have created a team since applying. Accepting would detach them
  # and leave that team captainless with members -- the same refusal as
  # applying, checked again because time has passed.
  it "refuses if the applicant has since become a captain" do
    own = create_team(:captain => @applicant)
    sign_in(@captain)

    post accept_join_request_path(@join_request)

    expect(@join_request.reload.status).to eq("new")
    expect(@applicant.reload.team).to eq(own)
  end

  it "refuses to decide a request that is no longer pending" do
    @join_request.reject!
    sign_in(@captain)

    post accept_join_request_path(@join_request)

    expect(@join_request.reload.status).to eq("rejected")
    expect(@applicant.reload.team).to be_nil
  end
end
