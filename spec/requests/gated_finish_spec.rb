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
      .tap { |p| p.update!(:finished_at => 1.hour.ago) }
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

      post post_answer_path(:game_id => game.id), :params => { :answer => "anything" }

      expect(attempt.reload.current_level).to eq(one)
      expect(attempt.finished_at).to be_nil
    end

    it "shows its own message, not the stranger's error" do
      game, team, captain, one, pass = gated_setup
      create_game_passing(:game => game, :team => team, :game_run => nil,
                          :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("errors.access_revoked"))
      expect(response.body).not_to include(I18n.t("errors.no_access_pass"))
    end

    it "still lets a team with a replacement pass play" do
      game, team, captain, one, pass = gated_setup
      create_game_passing(:game => game, :team => team, :game_run => nil,
                          :access_pass => pass, :level => one)
      pass.update!(:revoked_at => Time.now)
      create_access_pass(:game => game, :team => team)
      sign_in(captain)

      get show_current_level_path(:game_id => game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("errors.access_revoked"))
    end
  end
end
