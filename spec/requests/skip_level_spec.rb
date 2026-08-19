require "rails_helper"

describe "skipping a level", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Built through the real fixtures: a team with a captain and one other
  # member, on a game that allows two skips.
  # create_game_passing builds its team with `create_team` and NO options, so
  # that team has no captain and `team.captain` is nil. Every example here
  # signs in as the captain, so the team is built explicitly.
  #
  # starts_at lives on the game's CURRENT RUN, not on the games table itself
  # -- build_game's :starts_at default (2099) is a plain column value that
  # ensure_game_is_started never reads. set_game_schedule! is what actually
  # opens the run; without it every action here 401s with "game not started"
  # regardless of what create_game was given.
  def skippable
    captain = create_user
    member  = create_user
    team    = create_team(:captain => captain, :members => [ member ])
    game    = create_game(:max_skips => 2, :skip_points_fine => 25, :points_enabled => true)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:level => one, :team => team)
    [ game, passing, captain, member ]
  end

  it "shows the captain a confirmation stating the cost and the allowance" do
    game, passing, captain, _member = skippable
    sign_in(captain)

    get confirm_skip_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("25")
    expect(response.body).to include(I18n.t("game_passings.confirm_skip.remaining", :count => passing.skips_left))
  end

  # The GET must not perform the skip -- if it does, a link preview or a
  # back-button press spends the team's points.
  it "does not skip anything on the confirmation page itself" do
    game, passing, captain, _member = skippable
    sign_in(captain)

    get confirm_skip_path(:game_id => game.id)

    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
    expect(passing.reload.skips_left).to eq(2)
  end

  it "skips on the POST" do
    game, passing, captain, _member = skippable
    sign_in(captain)

    post skip_level_path(:game_id => game.id)

    expect(passing.reload.skips_left).to eq(1)
    expect(PointTransaction.where(:game_passing_id => passing.id,
                                  :reason => "level_skipped").count).to eq(1)
  end

  it "refuses a member who is not the captain" do
    game, passing, _captain, member = skippable
    sign_in(member)

    post skip_level_path(:game_id => game.id)

    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  it "is not offered at all when the game allows no skips" do
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:max_skips => 0)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    create_game_passing(:level => one, :team => team)
    sign_in(captain)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("game_passings.show_current_level.skip_level"))
  end
end
