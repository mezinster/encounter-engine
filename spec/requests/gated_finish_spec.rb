require "rails_helper"

describe "a paid game's ending", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A gated game with two levels, a team with a captain, and a live pass.
  def gated_setup
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:access_mode => "pass_required")
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    pass    = create_access_pass(:game => game, :team => team)
    [ game.reload, team, captain, one, pass ]
  end

  def finished_attempt(game, team, pass)
    create_game_passing(:game => game, :team => team, :game_run => nil,
                        :access_pass => pass, :level => game.levels.first)
      # current_level nil, not just finished_at set: that is what a REAL
      # finish looks like (GamePassing#advance! -- current_level.next is nil
      # off the last level), and it is exactly the shape TICKET #83 and F2
      # of the fix-round-2 review are about -- a finished attempt with a
      # level still attached would not exercise either bug.
      .tap { |p| p.update!(:finished_at => 1.hour.ago, :current_level => nil) }
  end

  it "serves a finished attempt instead of refusing it" do
    game, team, captain, _one, pass = gated_setup
    attempt = finished_attempt(game, team, pass)
    sign_in(captain)

    passings_before = GamePassing.count

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok).or have_http_status(:found)
    expect(response.body).not_to include(I18n.t("errors.no_access_pass"))
    # The fix must not enrol them again or consume anything.
    expect(GamePassing.count).to eq(passings_before)
    expect(attempt.reload.finished_at).not_to be_nil
  end

  it "still gives a fresh attempt when another live pass remains" do
    game, team, captain, one, pass = gated_setup
    finished_attempt(game, team, pass)
    create_access_pass(:game => game, :team => team)
    sign_in(captain)

    expect { get show_current_level_path(:game_id => game.id) }
      .to change { GamePassing.count }.by(1)

    fresh = GamePassing.order(:id).last
    expect(fresh.finished_at).to be_nil
    expect(fresh.current_level).to eq(one)
  end

  it "refuses a team that never had a pass" do
    game, _team, _captain, _one, _pass = gated_setup
    stranger = create_user
    create_team(:captain => stranger)
    sign_in(stranger)

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:unauthorized)
    expect(GamePassing.count).to eq(0)
  end

  describe "a revoked pass" do
    it "stops a team already playing, without advancing anything" do
      game, team, captain, one, pass = gated_setup
      attempt = create_game_passing(:game => game, :team => team, :game_run => nil,
                                    :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      sign_in(captain)

      passings_before = GamePassing.count
      transactions_before = PointTransaction.count

      # The CORRECT answer -- a wrong one would not advance the level either
      # way, whether or not revocation is enforced, and would make this
      # example pass under total non-enforcement.
      post post_answer_path(:game_id => game.id), :params => { :answer => one.correct_answer }

      expect(response).to have_http_status(:found)
      expect(attempt.reload.current_level).to eq(one)
      expect(attempt.finished_at).to be_nil
      expect(GamePassing.count).to eq(passings_before)
      expect(PointTransaction.count).to eq(transactions_before)
    end

    it "shows its own message, not the stranger's error" do
      game, team, captain, one, pass = gated_setup
      create_game_passing(:game => game, :team => team, :game_run => nil,
                          :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      sign_in(captain)

      passings_before = GamePassing.count

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("errors.access_revoked"))
      expect(response.body).not_to include(I18n.t("errors.no_access_pass"))
      expect(GamePassing.count).to eq(passings_before)
    end

    it "refuses a team with no attempt at all whose only pass was revoked" do
      game, _team, captain, _one, pass = gated_setup
      pass.update!(:revoked_at => Time.now)
      sign_in(captain)

      passings_before = GamePassing.count

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("errors.access_revoked"))
      expect(response.body).not_to include(I18n.t("errors.no_access_pass"))
      expect(GamePassing.count).to eq(passings_before)
    end

    it "still lets a team with a replacement pass play" do
      game, team, captain, one, pass = gated_setup
      original = create_game_passing(:game => game, :team => team, :game_run => nil,
                                     :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      replacement = create_access_pass(:game => game, :team => team)
      sign_in(captain)

      expect { get show_current_level_path(:game_id => game.id) }
        .to change { GamePassing.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("errors.access_revoked"))

      # A FRESH attempt, not the revoked one carried forward: bound to the
      # replacement pass, starting at level 1.
      fresh = GamePassing.order(:id).last
      expect(fresh.id).not_to eq(original.id)
      expect(fresh.access_pass_id).to eq(replacement.id)
      expect(fresh.current_level).to eq(one)
      expect(fresh.finished_at).to be_nil

      # The original, revoked-pass attempt is left exactly as it was.
      expect(original.reload.access_pass_id).to eq(pass.id)
      expect(original.current_level).to eq(one)
      expect(original.finished_at).to be_nil
    end
  end

  # A finished attempt is now SERVED rather than refused (see above), which
  # made every run-touching action on this controller reachable for it too --
  # not just the read-only show_current_level/post_answer pair that already
  # guarded themselves. These two are the ones that were not: exit_game
  # writes unconditionally, and get_current_level_tip dereferences a
  # current_level a finished attempt does not have.
  describe "a finished attempt stays read-only" do
    it "is not rewritten or dropped from standings by exit_game" do
      game, team, captain, _one, pass = gated_setup
      attempt = finished_attempt(game, team, pass)
      # to_i: sqlite round-trips finished_at at microsecond precision,
      # which a fresh Time.now capture would not exactly match even
      # unmutated.
      original_finished_at = attempt.finished_at.to_i
      sign_in(captain)

      passings_before = GamePassing.count

      post exit_game_path(:game_id => game.id)

      expect(response).to have_http_status(:found)
      expect(attempt.reload.finished_at.to_i).to eq(original_finished_at)
      expect(attempt.status).to be_nil
      expect(game.reload.pass_standings.map(&:id)).to include(attempt.id)
      expect(GamePassing.count).to eq(passings_before)
    end

    it "does not 500 the hint poller" do
      game, team, captain, _one, pass = gated_setup
      finished_attempt(game, team, pass)
      sign_in(captain)

      get get_current_level_tip_path(:game_id => game.id)

      expect(response).to have_http_status(:found)
    end
  end
end
