require "rails_helper"

# Discovery for S4: somewhere to see teams and apply to one. `resources
# :teams` already routed index and it 404'd via ActionNotFound, so this
# fills an existing slot rather than adding a route.
#
# Checked before writing: no frozen scenario visits a teams LIST --
# create-team.feature only visits /teams/new -- so this page carries no
# acceptance assertions.
describe "the teams index", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Was "refuses a guest", asserting the redirect that `require_authentication!`
  # produced. The page is the team leaderboard and is now public: teams#show
  # already was, so a team's name, captain and per-run points were readable
  # without an account before this change -- index widens the same door rather
  # than opening a new one.
  it "shows the standings to a guest" do
    captain = create_user
    team = create_team(:captain => captain)

    get teams_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(team.name)
    expect(response.body).to include(captain.nickname)
  end

  # A guest has no application to make: TeamJoinRequestsController#create
  # requires authentication, so rendering the control would be a promise the
  # action refuses to keep -- the same reasoning as the captain and own-team
  # cases below.
  it "does not offer a guest an apply form" do
    team = create_team(:captain => create_user)

    get teams_path

    expect(response.body).not_to include(team_join_requests_path(:team_id => team.id))
  end

  it "lists teams with their captains" do
    captain = create_user
    team = create_team(:captain => captain)
    sign_in(create_user)

    get teams_path

    expect(response.body).to include(team.name)
    expect(response.body).to include(captain.nickname)
  end

  it "offers an apply form, as a POSTing form, to a teamless viewer" do
    team = create_team(:captain => create_user)
    sign_in(create_user)

    get teams_path

    # Two steps rather than one ordered regex: form_with emits action before
    # method, and an ordered pattern fails for the wrong reason.
    form_tag = response.body[
      %r{<form[^>]*action="#{Regexp.escape(team_join_requests_path(:team_id => team.id))}"[^>]*>}
    ]
    expect(form_tag).not_to be_nil
    expect(form_tag).to include('method="post"')
  end

  it "does not offer it for the viewer's own team" do
    viewer = create_user
    own = create_team(:captain => create_user)
    own.members << viewer
    sign_in(viewer.reload)

    get teams_path

    expect(response.body).not_to include(team_join_requests_path(:team_id => own.id))
  end

  # A captain must hand over or leave first, so offering the control would be
  # a promise the action refuses to keep.
  it "does not offer it to a captain" do
    captain = create_user
    create_team(:captain => captain)
    other = create_team(:captain => create_user)
    sign_in(captain.reload)

    get teams_path

    expect(response.body).not_to include(team_join_requests_path(:team_id => other.id))
  end

  it "does not offer it where the viewer already has a pending application" do
    viewer = create_user
    team = create_team(:captain => create_user)
    TeamJoinRequest.create!(:user => viewer, :team => team)
    sign_in(viewer)

    get teams_path

    expect(response.body).not_to include(team_join_requests_path(:team_id => team.id))
  end

  # N+1 slope guard, mirroring the admin console's: the view renders each
  # team's captain and member count. Compares a small page against a larger
  # one so the assertion is about the gradient, not a magic number.
  it "keeps the query count flat as the number of teams grows" do
    sign_in(create_user)
    2.times { create_team(:captain => create_user) }
    small = count_queries { get teams_path }

    6.times { create_team(:captain => create_user) }
    large = count_queries { get teams_path }

    expect(large).to be <= small + 1
  end

  # The same guard on the guest path, which skips the pending-applications
  # query entirely and so runs different code. This file's own comment above
  # records that this class of guard has been broken repeatedly; a public page
  # is the one most worth holding flat.
  it "keeps the query count flat for a guest as the number of teams grows" do
    2.times { create_team(:captain => create_user) }
    small = count_queries { get teams_path }

    6.times { create_team(:captain => create_user) }
    large = count_queries { get teams_path }

    expect(large).to be <= small + 1
  end
end
