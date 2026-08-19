require "rails_helper"

describe "an operator skipping a level for a team", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "skips, and records the operator as the actor" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 1, :skip_points_fine => 25)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    two     = create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)
    sign_in(author)

    post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).to have_http_status(:found)
    expect(passing.reload.current_level).to eq(two)
    row = PointTransaction.find_by(:game_passing_id => passing.id, :reason => "level_skipped")
    expect(row.created_by_id).to eq(author.id)
  end

  # The operator shares skip_level! and therefore every refusal it makes. The
  # game is live -- set_game_schedule! puts starts_at in the past -- so this
  # is genuinely the cap refusing the request, not ensure_game_is_live doing
  # it for an unrelated reason and the assertions below passing vacuously.
  it "is bound by the same cap as the team" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 0)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)
    sign_in(author)

    post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).to have_http_status(:found)
    expect(passing.reload.current_level).to eq(one)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  # Whole-branch F1, the operator's half and the reason the refusal moved into
  # the model. InterventionsController treats a paused game as live on purpose
  # -- #resume has to stay reachable -- so this request reaches skip_level!
  # with every filter satisfied, and only the model can turn it away. Before
  # the fix it succeeded, advancing the team and stamping a level clock five
  # minutes ahead of the paused countdown.
  it "refuses while the game is paused, leaving the level and the ledger alone" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 1, :skip_points_fine => 25,
                          :points_enabled => true)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)
    sign_in(author)
    game.pause!

    post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).to have_http_status(:found)
    expect(passing.reload.current_level).to eq(one)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  # Whole-branch F3. max_skips defaults to 0 and is itself the feature switch,
  # so an unconditional button sat on every team of every existing game and
  # could only ever produce a refusal. The positive case is asserted in the
  # same example so "the button is absent" cannot pass because the panel, the
  # page or the whole request was absent.
  describe "the button on the stats page" do
    def stats_page_for(max_skips)
      author  = create_user
      game    = create_game(:author => author, :max_skips => max_skips,
                            :skip_points_fine => 25, :points_enabled => true)
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      one     = create_level(:game => game, :position => 1)
      create_level(:game => game, :position => 2)
      passing = create_game_passing(:game => game, :level => one)
      sign_in(author)
      [ game, passing ]
    end

    it "is offered when the game allows skips and the team has some left" do
      game, _passing = stats_page_for(1)

      get game_stats_path(game)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("interventions.skip_level"))
    end

    it "is not offered on a game that allows no skips" do
      game, _passing = stats_page_for(0)

      get game_stats_path(game)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("interventions.skip_level"))
    end

    it "is not offered once the team's allowance is spent" do
      game, passing = stats_page_for(1)
      post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)
      expect(passing.reload.skips_left).to eq(0)

      get game_stats_path(game)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("interventions.skip_level"))
    end
  end

  it "refuses a signed-out stranger" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 1)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)

    post skip_team_level_path(:game_id => game.id, :team_id => passing.team_id)

    expect(response).to redirect_to(login_path)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end

  # A4. The button already hides when the game allows no skips or the allowance
  # is spent. It did not hide for a run that is over, so an operator was
  # offered a control whose only possible outcome is a refusal.
  it "does not offer the skip button for a run the author ended" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 2, :skip_points_fine => 25)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    passing = create_game_passing(:game => game, :level => one)
    passing.end!
    sign_in(author)

    get game_stats_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("interventions.skip_level"))
  end

  it "still offers it for a run that is live" do
    author  = create_user
    game    = create_game(:author => author, :max_skips => 2, :skip_points_fine => 25)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    create_game_passing(:game => game, :level => one)
    sign_in(author)

    get game_stats_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("interventions.skip_level"))
  end
end
