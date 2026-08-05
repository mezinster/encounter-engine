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

  # N+1 guard: the view renders game.game_passings.size per row. Without
  # game_passings preloaded, that is one extra COUNT query per game -- the
  # query count would climb with the number of games shown, exactly the
  # thing a screen whose whole job is listing everything can least afford.
  # Compares a small fixture against a larger one rather than pinning a
  # magic number, so the assertion is about the SLOPE (flat) rather than a
  # single count that would break on any unrelated query added elsewhere.
  it "keeps the query count flat as the number of games grows" do
    sign_in(superadmin)

    def make_played_games(count)
      count.times do
        game = create_game(:author => superadmin, :is_draft => false)
        create_game_passing(:level => create_level(:game => game))
      end
    end

    make_played_games(2)
    small_query_count = count_queries { get admin_games_path }

    make_played_games(6)
    large_query_count = count_queries { get admin_games_path }

    expect(large_query_count).to eq(small_query_count)
  end
end
