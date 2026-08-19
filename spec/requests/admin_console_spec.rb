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

  # Two-minors cleanup, cheap-minor 1 of the whole-branch review: tightened
  # from `not_to have_http_status(:ok)`, which a 500 also satisfies. An
  # anonymous visitor hits require_authentication! before require_superadmin!
  # ever runs, so this is Authentication::Unauthenticated (redirect to
  # login), not Authentication::Unauthorized (401) -- verified live rather
  # than assumed. The signed-in-but-not-admin case below does reach
  # require_superadmin! and gets the 401.
  it "refuses an anonymous visitor" do
    get admin_games_path
    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(login_path)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(author)
    get admin_games_path
    expect(response).to have_http_status(:unauthorized)
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

  # Finding 3 of the whole-branch review: this view's status branches were
  # withdrawn / draft / started? -> running / else scheduled, with no
  # finished branch, while Game.count_by_status (and its comment, which
  # claims the two screens deliberately agree) has five buckets including
  # :finished. A game with author_finished_at set read "Running" here and
  # "Finished" on the dashboard.
  it "labels a finished game as finished, matching the dashboard's bucket rather than running" do
    now = Time.now
    Time.stub(:now => now - 1)
    finished = create_game(:author => author, :is_draft => false, :starts_at => now)
    Time.stub(:now => now + 1)
    finished.finish_game!
    sign_in(superadmin)

    get admin_games_path

    expect(response.body).to include(I18n.t("admin.games.index.finished"))
    expect(response.body).not_to include(I18n.t("admin.games.index.running"))
  end

  it "offers withdrawal but not deletion for a game that has been played" do
    played = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => played))
    sign_in(superadmin)

    get admin_games_path

    # The console links to the withdrawal FORM, not the POST endpoint --
    # withdrawal now carries a required reason and a choice of mode.
    expect(response.body).to include(new_withdrawal_game_path(played))
    expect(response.body).not_to include(delete_game_path(played))
  end

  # The unfinish button is the only UI door out of the "Завершена" state
  # (everything else about that state is one-way -- see
  # docs/superpowers/specs/2026-08-08-superadmin-unfinish-design.md), so its
  # visibility is part of the feature: present exactly on finished games.
  #
  # The assertion pins a POSTing FORM, not merely the path: this app has no
  # Turbo and no rails-ujs, so a link_to with method: :post silently issues a
  # GET and 404s against the POST-only route -- a "tidying" that no
  # path-presence check would catch (the same class of gap PR #33's review
  # found in the routing examples: everything asserted the new verb worked,
  # nothing asserted the old one had stopped). Mutation-verified: swapping the
  # view's button_to for link_to fails this example.
  it "offers revival, as a POST form, for a finished game and not for a running one" do
    finished = create_game(:author => author, :is_draft => false)
    finished.finish_game!
    running = create_game(:author => author, :is_draft => false)
    sign_in(superadmin)

    get admin_games_path

    expect(response.body).to match(
      %r{<form[^>]*method="post"[^>]*action="#{Regexp.escape(unfinish_game_path(finished))}"}
    )
    expect(response.body).not_to include(unfinish_game_path(running))
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
