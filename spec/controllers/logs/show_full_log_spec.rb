# -*- encoding : utf-8 -*-
require "rails_helper"

# SECURITY REGRESSION SPEC (see
# .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-S-report.md):
# show_full_log used to be reachable by ANY logged-in user -- deliberately
# left out of the :ensure_author list -- so a team still mid-game could read
# every remaining answer code for the game via this action. The rule
# implemented here (LogsController#ensure_full_log_access): allowed for the
# game's author, or for a player whose team has a *finished* GamePassing for
# this game (features/logs/log.feature:105 and :113); blocked for a team
# still playing and for anyone with no team at all.
RSpec.describe LogsController, "#show_full_log", type: :controller do
  before :each do
    now = Time.now
    Time.stub(:now => now - 1)
    @author = create_user
    @game = create_game :author => @author, :starts_at => now
    @level = create_level :game => @game, :correct_answer => "SECRETCODE"
    @game.reload
    Time.stub(:now => now + 1)
  end

  describe "security filters" do
    it "raises Unauthenticated exception for a guest" do
      assert_unauthenticated { perform_request }
    end

    it "allows the game's author" do
      perform_request(:as_user => @author)
      expect(response).to have_http_status(:success)
    end

    it "allows a player whose team has finished the game" do
      captain = create_user
      team = create_team(:captain => captain)
      create_game_passing(:team => team, :level => @level, :finished_at => Time.now)

      perform_request(:as_user => captain)
      expect(response).to have_http_status(:success)
    end

    # The actual hole: a team still playing must not be able to read the
    # answer codes for the rest of the game.
    it "raises Unauthorized exception for a player whose team is still mid-game" do
      captain = create_user
      team = create_team(:captain => captain)
      create_game_passing(:team => team, :level => @level)

      assert_unauthorized { perform_request(:as_user => captain) }
    end

    it "raises Unauthorized exception for a logged-in user with no team at all" do
      lonely_user = create_user
      assert_unauthorized { perform_request(:as_user => lonely_user) }
    end
  end

  def perform_request(opts = {})
    session[:user_id] = opts[:as_user]&.id
    get :show_full_log, params: { game_id: @game.id }
    response
  end
end
