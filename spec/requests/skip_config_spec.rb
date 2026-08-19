require "rails_helper"

describe "skip configuration through the game form", type: :request do
  let(:author) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A model-level example cannot catch a param that was never permitted, and
  # cannot catch a field missing from the form. This is the layer that can.
  it "saves the three settings the author typed" do
    game = create_game(:author => author)
    sign_in(author)

    put game_path(game), :params => { :game => { :max_skips => 3,
                                                 :skip_points_fine => 25,
                                                 :skip_time_penalty => 600 } }

    game.reload
    expect(game.max_skips).to eq(3)
    expect(game.skip_points_fine).to eq(25)
    expect(game.skip_time_penalty).to eq(600)
  end

  it "renders all three fields on the edit form" do
    game = create_game(:author => author)
    sign_in(author)

    get edit_game_path(game)

    expect(response.body).to include("game_max_skips")
    expect(response.body).to include("game_skip_points_fine")
    expect(response.body).to include("game_skip_time_penalty")
  end
end
