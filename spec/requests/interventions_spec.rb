# spec/requests/interventions_spec.rb
require "rails_helper"

describe "live-game interventions", type: :request do
  let(:author)     { create_user }
  let(:stranger)   { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  let(:game)    { g = create_game(:author => author); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "authorization" do
    it "refuses an anonymous visitor" do
      post pause_game_path(game)
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(login_path)
    end

    it "refuses a different author" do
      sign_in(stranger)
      post pause_game_path(game)
      expect(response).to have_http_status(:unauthorized)
      expect(game.reload.paused?).to be false
    end

    it "allows the game's own author" do
      sign_in(author)
      post pause_game_path(game)
      expect(game.reload.paused?).to be true
    end

    it "allows a superadmin on someone else's game" do
      sign_in(superadmin)
      post pause_game_path(game)
      expect(game.reload.paused?).to be true
    end

    # The lock exists so an operator can stop an author touching a game under
    # investigation. Live intervention has to be inside it, or the lock is
    # trivially sidestepped.
    it "refuses a locked game to its author but not to a superadmin" do
      game.update_column(:editing_locked_at, Time.now)

      sign_in(author)
      post pause_game_path(game)
      expect(response).to have_http_status(:unauthorized)
      expect(game.reload.paused?).to be false

      sign_in(superadmin)
      post pause_game_path(game)
      expect(game.reload.paused?).to be true
    end

    it "refuses a game that has not started" do
      future = create_game(:author => author)
      sign_in(author)

      post pause_game_path(future)

      expect(response).to have_http_status(:unauthorized)
      expect(future.reload.paused?).to be false
    end

    it "refuses a game the author has already finished" do
      game.update_column(:author_finished_at, Time.now)
      sign_in(author)

      post pause_game_path(game)

      expect(response).to have_http_status(:unauthorized)
    end

    # ensure_game_is_live's `!@game.draft?` clause. starts_at is in the past
    # (unlike the "has not started" example above) so draft is the only
    # condition making this game not-live.
    it "refuses a draft game" do
      draft = create_game(:author => author, :is_draft => true)
      draft.update_column(:starts_at, 1.hour.ago)
      sign_in(author)

      post pause_game_path(draft)

      expect(response).to have_http_status(:unauthorized)
      expect(draft.reload.paused?).to be false
    end

    # ensure_game_is_live's `!@game.withdrawn?` clause.
    it "refuses a withdrawn game" do
      withdrawn = create_game(:author => author)
      withdrawn.update_column(:starts_at, 1.hour.ago)
      withdrawn.update_column(:withdrawn_at, Time.now)
      sign_in(author)

      post pause_game_path(withdrawn)

      expect(response).to have_http_status(:unauthorized)
      expect(withdrawn.reload.paused?).to be false
    end

    # ensure_game_is_live's `return if @game.is_testing?` exemption -- the one
    # that lets an author rehearse a game that has not started yet.
    it "allows a testing game even though it has not started" do
      testing_game = create_game(:author => author, :is_testing => true)
      sign_in(author)

      post pause_game_path(testing_game)

      expect(response).not_to have_http_status(:unauthorized)
      expect(testing_game.reload.paused?).to be true
    end
  end

  # A guard that treated `paused?` as not-live would put resume behind a
  # condition only resume can clear -- an action no request could ever reach.
  # Sub-project B shipped exactly that defect, and its test passed while
  # measuring a different guard. This one drives resume through the controller
  # rather than calling the model, which is the only way to see it.
  describe "reachability while paused" do
    it "reaches resume on a paused game" do
      sign_in(author)
      post pause_game_path(game)

      post resume_game_path(game)

      expect(response).to have_http_status(:found)
      expect(game.reload.paused?).to be false
    end

    it "reaches the team interventions on a paused game" do
      passing
      sign_in(author)
      post pause_game_path(game)

      post reset_team_clock_path(:game_id => game.id, :team_id => passing.team_id)

      expect(response).to have_http_status(:found)
    end
  end

  describe "the team interventions" do
    before { sign_in(author) }

    it "moves a team to a level" do
      second = create_level(:game => game)
      passing

      post move_team_path(:game_id => game.id, :team_id => passing.team_id),
           :params => { :level_id => second.id }

      expect(passing.reload.current_level).to eq(second)
    end

    it "refuses a level from another game without changing anything" do
      other = create_level(:game => create_game)
      passing

      post move_team_path(:game_id => game.id, :team_id => passing.team_id),
           :params => { :level_id => other.id }

      expect(passing.reload.current_level).to eq(level)
      expect(response).to have_http_status(:found)
    end

    it "reinstates a team that quit" do
      passing.exit!

      post reinstate_team_path(:game_id => game.id, :team_id => passing.team_id)

      expect(passing.reload.exited?).to be false
    end
  end

  describe "auditing" do
    it "records a superadmin acting on someone else's game, naming the team" do
      passing
      sign_in(superadmin)

      expect {
        post reset_team_clock_path(:game_id => game.id, :team_id => passing.team_id)
      }.to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("reset_clock")
      expect(entry.target_id).to eq(game.id)
      expect(entry.details).to eq(passing.team.name)
    end

    it "records a pause" do
      sign_in(superadmin)
      expect { post pause_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("pause")
    end

    # B's rule: an author acting on their own game is ordinary use.
    it "records nothing for the author of the game" do
      sign_in(author)
      expect { post pause_game_path(game) }.not_to change { AdminAction.count }
    end

    # acting_as_operator? is "superadmin AND not the author" -- both examples
    # above only ever exercise one half each (a superadmin on someone else's
    # game, a plain author on their own). This is the conjunction: a
    # superadmin acting on a game they themselves authored must still record
    # nothing, or the log would bury every superadmin's ordinary games under
    # administrative noise.
    it "records nothing for a superadmin acting on their own game" do
      author.update!(:is_superadmin => true)
      sign_in(author)
      expect { post pause_game_path(game) }.not_to change { AdminAction.count }
    end
  end

  describe "the stats page controls" do
    it "offers pause to the author of a running game" do
      passing
      sign_in(author)

      get game_stats_path(:index, game)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pause_game_path(game))
    end

    it "offers resume instead once the game is paused" do
      passing
      game.pause!
      sign_in(author)

      get game_stats_path(:index, game)

      expect(response.body).to include(resume_game_path(game))
      expect(response.body).not_to include(pause_game_path(game))
    end

    it "offers the team controls" do
      passing
      sign_in(author)

      get game_stats_path(:index, game)

      expect(response.body).to include(reset_team_clock_path(:game_id => game.id, :team_id => passing.team_id))
    end
  end
end
