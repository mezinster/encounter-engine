require "rails_helper"

describe "configuring scoring", type: :request do
  let(:author) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "lets an author turn scoring on and set the values" do
    game = create_game(:author => author, :is_draft => true)
    sign_in(author)

    patch game_path(game), :params => { :game => { :points_enabled => "1",
                                                   :level_completion_points => "10",
                                                   :game_completion_points => "50" } }

    game.reload
    expect(game.points_enabled).to be true
    expect(game.level_completion_points).to eq(10)
    expect(game.game_completion_points).to eq(50)
  end

  it "lets an author set a per-level override" do
    game  = create_game(:author => author, :is_draft => true, :points_enabled => true)
    level = create_level(:game => game)
    sign_in(author)

    patch game_level_path(game, level), :params => { :level => { :points_award => "25" } }

    expect(level.reload.points_award).to eq(25)
  end
end
