require "rails_helper"

# Everything under app/services and the AccessPass/GamePassing model layer for
# commercial games was already built and tested; nothing in the UI pointed at
# it. This covers the two reachability gaps in GamesController#show and
# GamePassingsController#index (the author's live console).
describe "reaching the access-pass console for a gated game", type: :request do
  let(:author)     { create_user }
  let(:operator)   { u = create_user; u.update!(:is_operator => true); u }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:level)      { create_level }
  let(:game) do
    g = level.game
    g.update!(:author => author, :access_mode => "pass_required", :visibility => "listed")
    g
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "the link on the game's own page" do
    it "is hidden from a guest" do
      get game_path(game)
      expect(response.body).not_to include(game_access_passes_path(game))
    end

    it "is hidden from an ordinary author who is not an operator" do
      sign_in(author)
      get game_path(game)
      expect(response.body).not_to include(game_access_passes_path(game))
    end

    it "is shown to an operator" do
      sign_in(operator)
      get game_path(game)
      expect(response.body).to include(game_access_passes_path(game))
    end

    it "is shown to a superadmin" do
      sign_in(superadmin)
      get game_path(game)
      expect(response.body).to include(game_access_passes_path(game))
    end

    it "is hidden on a scheduled game, even to an operator" do
      scheduled = create_level.game
      sign_in(operator)
      get game_path(scheduled)
      expect(response.body).not_to include(game_access_passes_path(scheduled))
    end
  end

  # F1: the codes console (AccessCodesController) had no entry point at all --
  # game_access_codes_path was referenced only from inside app/views/access_codes/
  # itself, so an operator had to hand-type the URL to reach it.
  describe "the access-codes link on the game's own page" do
    it "is shown to an operator on a gated game, and points at the codes console" do
      sign_in(operator)
      get game_path(game)
      expect(response.body).to include(game_access_codes_path(game))
    end
  end

  describe "GamePassingsController#index on a gated game" do
    it "lists the game's gated attempts instead of an empty run-scoped list" do
      pass = create_access_pass(:game => game, :team => create_team)
      attempt = create_game_passing(:game => game, :team => pass.team, :level => level,
                                    :game_run => nil, :access_pass => pass)
      sign_in(author)

      get game_stats_path(game_id: game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(attempt.team.name)
    end

    # The scheduled branch (current_run.passings) must stay byte-identical:
    # this proves a scheduled game's console is untouched by the change.
    it "still lists a scheduled game's current-run passings" do
      scheduled_game = create_level.game
      scheduled_game.update!(:author => author)
      scheduled_level = scheduled_game.levels.first
      set_game_schedule!(scheduled_game, :starts_at => 1.hour.ago)
      passing = create_game_passing(:level => scheduled_level, :game => scheduled_game)
      sign_in(author)

      get game_stats_path(game_id: scheduled_game.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(passing.team.name)
    end
  end
end
