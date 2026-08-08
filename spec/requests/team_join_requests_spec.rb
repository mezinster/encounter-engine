require "rails_helper"

# S4 of docs/superpowers/specs/2026-08-08-team-membership-programme-design.md:
# a user applies, the target team's captain decides. This file covers
# applying; deciding is in team_join_decisions_spec.rb.
describe "applying to join a team", type: :request do
  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). create_user sets the
  # password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before :each do
    @applicant = create_user
    @target = create_team(:captain => create_user)
  end

  it "creates a pending request for a teamless user" do
    sign_in(@applicant)

    expect do
      post team_join_requests_path(:team_id => @target.id)
    end.to change(TeamJoinRequest, :count).by(1)

    request = TeamJoinRequest.order(:id).last
    expect(request.user).to eq(@applicant)
    expect(request.team).to eq(@target)
    expect(request.status).to eq("new")
  end

  it "creates one for a plain member of another team, who is transferring" do
    source = create_team(:captain => create_user)
    source.members << @applicant
    sign_in(@applicant.reload)

    expect do
      post team_join_requests_path(:team_id => @target.id)
    end.to change(TeamJoinRequest, :count).by(1)
  end

  # Refusal 1: accepting would detach them and leave their own team
  # captainless WITH members -- the bricked state. Hand over or leave first.
  it "refuses a captain, naming the remedy" do
    captain = create_user
    create_team(:captain => captain)
    sign_in(captain.reload)

    post team_join_requests_path(:team_id => @target.id)

    expect(flash[:alert]).to eq(I18n.t("team_join_requests.captain_must_hand_over_first"))
  end

  # The data property, separate from the message: RSpec fails fast.
  it "creates nothing when a captain applies" do
    captain = create_user
    create_team(:captain => captain)
    sign_in(captain.reload)

    expect do
      post team_join_requests_path(:team_id => @target.id)
    end.not_to change(TeamJoinRequest, :count)
  end

  # Refusal 2.
  it "refuses an application to the team the user is already in" do
    own = create_team(:captain => create_user)
    own.members << @applicant
    sign_in(@applicant.reload)

    expect do
      post team_join_requests_path(:team_id => own.id)
    end.not_to change(TeamJoinRequest, :count)
  end

  # Refusal 3 (D1): member-initiated changes wait for the race to end.
  it "refuses while the applicant's current team is mid-race" do
    source = create_team(:captain => create_user)
    source.members << @applicant
    create_game_passing(:team => source, :level => create_level)
    sign_in(@applicant.reload)

    expect do
      post team_join_requests_path(:team_id => @target.id)
    end.not_to change(TeamJoinRequest, :count)
  end

  # Refusal 4: the partial unique index would raise RecordNotUnique, which
  # would be a 500. The controller refuses first so a double-clicked button
  # is a message, not an error page.
  it "refuses a second pending application to the same team" do
    TeamJoinRequest.create!(:user => @applicant, :team => @target)
    sign_in(@applicant)

    expect do
      post team_join_requests_path(:team_id => @target.id)
    end.not_to change(TeamJoinRequest, :count)

    expect(flash[:alert]).to eq(I18n.t("team_join_requests.already_applied"))
  end

  # ...but a refused applicant may try again, which is why the index is
  # scoped to the live status.
  it "allows a fresh application after an earlier one was rejected" do
    TeamJoinRequest.create!(:user => @applicant, :team => @target).reject!
    sign_in(@applicant)

    expect do
      post team_join_requests_path(:team_id => @target.id)
    end.to change(TeamJoinRequest, :count).by(1)
  end

  it "refuses an unknown team" do
    sign_in(@applicant)

    expect do
      post team_join_requests_path(:team_id => 0)
    end.not_to change(TeamJoinRequest, :count)
  end

  it "refuses a guest" do
    expect do
      post team_join_requests_path(:team_id => @target.id)
    end.not_to change(TeamJoinRequest, :count)

    expect(response).to redirect_to(login_path)
  end
end
