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

  # Whole-branch F2(a). charge_skip! zeroes the amount when points are off, so
  # a page announcing the fine states a price the model will not charge. The
  # fine is deliberately NON-ZERO here: with 0 the assertion would be
  # satisfied by the fixture rather than by the code.
  it "does not promise points on a game whose points are switched off" do
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:max_skips => 2, :skip_points_fine => 25,
                          :skip_time_penalty => 45, :points_enabled => false)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    create_game_passing(:level => one, :team => team)
    sign_in(captain)

    get confirm_skip_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      I18n.t("game_passings.confirm_skip.cost_time_only", :seconds => 45))
    expect(response.body).not_to include(
      I18n.t("game_passings.confirm_skip.cost", :points => 25, :seconds => 45))
  end

  # Whole-branch F2(b). skip_time_penalty is SECONDS; rendering it as whole
  # minutes is integer division, so 45 seconds read as "0 мин" on the one
  # screen whose job is stating the cost.
  it "states a sub-minute penalty instead of rounding it to zero" do
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:max_skips => 2, :skip_points_fine => 25,
                          :skip_time_penalty => 45, :points_enabled => true)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    create_game_passing(:level => one, :team => team)
    sign_in(captain)

    get confirm_skip_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      I18n.t("game_passings.confirm_skip.cost", :points => 25, :seconds => 45))
  end

  # Whole-branch F4. The play screen hides the button on skips_allowed? AND
  # skips_left.positive?; this page is reachable directly -- bookmark, back
  # button -- and checked only the first.
  it "redirects away from the confirmation page once the allowance is spent" do
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:max_skips => 1, :skip_points_fine => 25, :points_enabled => true)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:level => one, :team => team)
    sign_in(captain)

    post skip_level_path(:game_id => game.id)
    expect(passing.reload.skips_left).to eq(0)

    get confirm_skip_path(:game_id => game.id)

    expect(response).to redirect_to(show_current_level_path(:game_id => game.id))
  end

  # Whole-branch F1, the captain's half. Two guards refuse this now -- the
  # controller's ensure_game_not_paused and, behind it, skip_level! itself --
  # and the model one is what makes the operator's path (operator_skip_spec)
  # agree with this one.
  it "refuses the captain while the game is paused" do
    game, passing, captain, _member = skippable
    level_before = passing.current_level
    sign_in(captain)
    game.pause!

    post skip_level_path(:game_id => game.id)

    expect(response).to have_http_status(:found)
    expect(passing.reload.current_level).to eq(level_before)
    expect(passing.reload.skips_left).to eq(2)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
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

  # Three different guards refuse three different actors. Asserting the
  # distinct status codes (rather than "not authorized" in general) pins that
  # removing any ONE guard fails a specific example here, instead of being
  # silently absorbed by whichever guard is left.
  it "refuses an own-team member who is not the captain, with 401" do
    game, passing, _captain, member = skippable
    sign_in(member)

    post skip_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  # A different guard entirely: ensure_team_captain passes (this user IS a
  # captain, just not of a team registered for THIS game), so it is
  # find_or_create_game_passing's may_start_passing? check that refuses --
  # the team has no accepted GameEntry for this game's current run.
  it "refuses the captain of a different, unrelated team, with 401" do
    game, passing, _captain, _member = skippable
    other_captain = create_user
    create_team(:captain => other_captain)
    sign_in(other_captain)

    post skip_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  # require_authentication! -- Authentication::Unauthenticated, not
  # Unauthorized -- redirects rather than 401s.
  it "redirects a signed-out visitor to the login page" do
    game, passing, _captain, _member = skippable

    post skip_level_path(:game_id => game.id)

    expect(response).to redirect_to(login_path)
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

  # The easiest case to get wrong: skips_allowed? and skips_left.positive?
  # are two SEPARATE conditions gating the button. Dropping either one leaves
  # the button on screen for a team that can no longer use it -- they would
  # click it and land on a refusal.
  it "hides the skip button once the team's allowance is exhausted" do
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:max_skips => 1, :skip_points_fine => 25, :points_enabled => true)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:level => one, :team => team)
    sign_in(captain)

    post skip_level_path(:game_id => game.id)
    expect(passing.reload.skips_left).to eq(0)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("game_passings.show_current_level.skip_level"))
  end
end
