require "rails_helper"

# app/views/invitations/new.html.erb used to interpolate nickname and email
# directly into a JS string literal. ERB's html_escape does not escape "\",
# so a nickname ending in a backslash escaped the closing quote and merged
# the two literals, putting the email value in executable position.
describe "the invitation autocomplete payload", type: :request do
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }

  before do
    captain.update!(:team => team)
    put login_path, :params => { :email => captain.email, :password => "1234" }
  end

  it "does not let a backslash nickname break out of the emitted payload" do
    hostile = create_user
    hostile.update!(:nickname => "evil\\")

    get new_invitation_path

    expect(response).to have_http_status(:ok)
    # The breakout signature: a backslash immediately before a closing quote
    # inside the script block.
    expect(response.body).not_to include("evil\\'")
    expect(response.body).not_to include("data.push(")
    # JSON escapes it as a doubled backslash, which no JS parser treats as
    # a quote escape.
    expect(response.body).to include('"evil\\\\"')
  end

  it "does not emit any user's email address" do
    other = create_user

    get new_invitation_path

    expect(response.body).not_to include(other.email)
    expect(response.body).not_to include(captain.email)
  end

  it "still offers the other users' nicknames" do
    other = create_user

    get new_invitation_path

    expect(response.body).to include('id="invitation-nicknames"')
    expect(response.body).to include(other.nickname)
  end
end
