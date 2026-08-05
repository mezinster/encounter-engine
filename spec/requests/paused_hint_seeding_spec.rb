require "rails_helper"

# Review finding, fix round 1: show_current_level.html.erb seeds
# level_hint_updater.js's countdown with Hint#available_in, and that call
# site was calling it with ONE argument -- silently falling back to the new
# `now = Time.now` default instead of the game's frozen effective_now. During
# a pause that seeds a countdown against wall-clock time instead of the
# paused instant, which can come out too small (even negative), making the
# client poll get_current_level_tip too early and hit the pre-existing nil
# `hint.translated` 500 documented in the review (a separate, already-known
# weakness -- not touched here).
#
# This spec exercises the actual view render (a model/controller spec on
# GamePassing or Hint alone cannot see a dropped argument at a single call
# site in an .erb file), and is deliberately shaped so dropping the second
# argument to #available_in in the view makes it fail: the wrong (wall-clock)
# value keeps drifting further from the correct one for as long as the pause
# holds, so travel_to-ing well past the pause moment before asserting is what
# makes the two values provably different rather than coincidentally equal.
describe "paused hint seeding", type: :request do
  # Verified in spec/requests/withdrawal_spec.rb: GET /login is the form, PUT
  # /login (sessions#update) is the actual login action.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "seeds initialCountdownValue from the game's paused instant, not wall-clock time" do
    author = create_user
    game = create_game(:author => author)
    # starts_at in the past is what makes ensure_game_is_started accept the
    # request -- same technique spec/models/game/pausing_spec.rb uses, and
    # for the same reason: a live game fails its own future-start validation,
    # so this has to go through update_column rather than update!.
    game.update_column(:starts_at, 1.hour.ago)

    level = create_level(:game => game)
    create_hint(:level => level, :delay => 20 * 60) # 20-minute hint, still upcoming

    player = create_user
    team = create_team(:captain => player)
    game_passing = create_game_passing(:level => level, :team => team)
    game_passing.update_column(:current_level_entered_at, 5.minutes.ago)

    game.pause!
    paused_at = game.reload.paused_at

    sign_in(player)

    travel_to(30.minutes.from_now) do
      get show_current_level_path(:game_id => game.id)
      expect(response).to have_http_status(:ok)

      match = response.body.match(/initialCountdownValue:\s*(-?\d+)/)
      expect(match).to be_present
      seeded_value = match[1].to_i

      entered_at = game_passing.reload.current_level_entered_at
      frozen_value = (entered_at - paused_at).to_i + 20 * 60
      wall_clock_value = (entered_at - Time.now).to_i + 20 * 60 # what the bug would seed

      expect(frozen_value).not_to eq(wall_clock_value) # sanity: the two must differ to discriminate
      expect(seeded_value).to eq(frozen_value)
    end
  end
end
