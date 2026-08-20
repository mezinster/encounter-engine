require "rails_helper"

# A team that has finished a FREE game could destroy its own result.
#
# GameRun#passing_for is `passings.of_team(team).first` -- no finished? filter,
# exactly as the gated path was before the paid-game ending shipped. So
# exit_game stayed reachable after the run was over, and GamePassing#exit!
# stamps finished_at afresh AND sets status "exited": the run drops out of the
# finish protocol entirely.
#
# The button is on the play screen, so reaching it needs nothing unusual -- a
# back button after finishing is enough.
describe "a finished run's own controls", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A free, run-scoped game with a team that has a captain -- create_game_passing
  # builds its team via create_team with no options, so it has none.
  def free_game_mid_run
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    passing = create_game_passing(:level => one, :team => team)
    [ game.reload, passing, captain ]
  end

  # A REAL finish, not just a stamped column: GamePassing#advance! sets
  # current_level to current_level.next, which is nil on the last level, so a
  # finished passing has NO current level. Setting finished_at alone leaves a
  # level for the hint poller to dereference, and the poller example then
  # passes against the very bug it is written for.
  def finish!(passing)
    passing.update!(:finished_at => 2.hours.ago, :current_level => nil)
    passing
  end

  describe "when the run has finished" do
    it "does not let exit_game rewrite the result" do
      game, passing, captain = free_game_mid_run
      finish!(passing)
      finished_at_before = passing.reload.finished_at
      sign_in(captain)

      post exit_game_path(:game_id => game.id)

      passing.reload
      expect(passing.finished_at.to_i).to eq(finished_at_before.to_i)
      expect(passing.status).to be_nil
      expect(game.current_run.finished_teams).to include(passing.team)
    end

    it "does not 500 the hint poller" do
      game, passing, captain = free_game_mid_run
      finish!(passing)
      sign_in(captain)

      get get_current_level_tip_path(:game_id => game.id)

      expect(response.status).to be < 500
    end
  end

  # The positive control, and the half that matters: the guard must refuse a
  # FINISHED run without switching exiting off for a team still playing. An
  # example asserting only that a finished run is protected would pass against
  # a guard that refused everyone.
  describe "when the run is still going" do
    it "still lets a captain leave the race" do
      game, passing, captain = free_game_mid_run
      expect(passing.finished_at).to be_nil
      sign_in(captain)

      post exit_game_path(:game_id => game.id)

      passing.reload
      expect(passing.status).to eq("exited")
      expect(passing.finished_at).not_to be_nil
    end
  end
end
