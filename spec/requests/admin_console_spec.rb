require "rails_helper"

describe "the admin console", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  # create_user (spec/spec_helpers/fixtures_helper.rb) sets the password to
  # "1234", not "password" -- using the fixture's real password here.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an anonymous visitor" do
    get admin_games_path
    expect(response).not_to have_http_status(:ok)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(author)
    get admin_games_path
    expect(response).not_to have_http_status(:ok)
  end

  it "lists every game, including other people's drafts" do
    mine     = create_game(:author => superadmin, :is_draft => false)
    theirs   = create_game(:author => author,     :is_draft => true)
    sign_in(superadmin)

    get admin_games_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(mine.name)
    expect(response.body).to include(theirs.name)
  end

  it "offers withdrawal but not deletion for a game that has been played" do
    played = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => played))
    sign_in(superadmin)

    get admin_games_path

    expect(response.body).to include(withdraw_game_path(played))
    expect(response.body).not_to include(delete_game_path(played))
  end
end
