require "rails_helper"

describe "logs of a gated game", type: :request do
  let(:level)   { create_level }
  let(:game)    { g = level.game; g.update!(:access_mode => "pass_required", :visibility => "listed"); g }
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # The point of the column: two attempts by the SAME team in the SAME game
  # are indistinguishable by (game_id, team_id).
  it "attributes each answer to the attempt that submitted it" do
    first = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    post post_answer_path(:game_id => game.id), :params => { :answer => "wrong-one" }

    attempt_one = GamePassing.find_by(:access_pass_id => first.id)
    attempt_one.update!(:finished_at => Time.now)

    second = create_access_pass(:game => game, :team => team)
    get show_current_level_path(:game_id => game.id)
    post post_answer_path(:game_id => game.id), :params => { :answer => "wrong-two" }
    attempt_two = GamePassing.find_by(:access_pass_id => second.id)

    expect(Log.of_attempt(attempt_one).map(&:answer)).to eq([ "wrong-one" ])
    expect(Log.of_attempt(attempt_two).map(&:answer)).to eq([ "wrong-two" ])
  end

  # LogsController#show_full_log has no team_id param -- for a gated game it
  # must resolve "whose attempt" from the requesting user's own team, and
  # show only that attempt. A commercial run is a private purchase; one
  # customer's screen must never leak another customer's answers.
  it "shows the requesting team's own attempt on the full log, and no other team's" do
    own_pass = create_access_pass(:game => game, :team => team)
    sign_in(captain)
    get show_current_level_path(:game_id => game.id)
    post post_answer_path(:game_id => game.id), :params => { :answer => "own-code" }
    own_attempt = GamePassing.find_by(:access_pass_id => own_pass.id)
    own_attempt.update!(:finished_at => Time.now)

    other_captain = create_user
    other_team    = create_team(:captain => other_captain)
    other_pass    = create_access_pass(:game => game, :team => other_team)
    sign_in(other_captain)
    get show_current_level_path(:game_id => game.id)
    post post_answer_path(:game_id => game.id), :params => { :answer => "other-code" }
    other_attempt = GamePassing.find_by(:access_pass_id => other_pass.id)
    other_attempt.update!(:finished_at => Time.now)

    sign_in(captain)
    get show_full_log_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("own-code")
    expect(response.body).not_to include("other-code")
  end
end
