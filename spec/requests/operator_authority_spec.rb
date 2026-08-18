require "rails_helper"

describe "an operator's authority", type: :request do
  let(:author)   { create_user }
  let(:operator) { u = create_user; u.update!(:is_operator => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def gated_game
    g = create_game(:author => author, :is_draft => false)
    g.update!(:access_mode => "pass_required")
    g
  end

  it "lets an operator edit a gated game they did not author" do
    game = gated_game
    sign_in(operator)

    get edit_game_path(game)

    expect(response).to have_http_status(:ok)
  end

  # D2: the authority is scoped to gated games and nothing else. This is the
  # whole reason the clause is game-conditional rather than a bare widening.
  it "does NOT let an operator edit an ordinary game they did not author" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(operator)

    get edit_game_path(game)

    expect(response).to have_http_status(:unauthorized)
  end

  # ensure_author also gates levels, hints, questions and entries. An operator
  # must not reach a player's public game THROUGH its levels controller.
  it "does NOT let an operator add a level to an ordinary game" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(operator)

    get new_game_level_path(game)

    expect(response).to have_http_status(:unauthorized)
  end

  it "lets an operator add a level to a gated game" do
    game = gated_game
    sign_in(operator)

    get new_game_level_path(game)

    expect(response).to have_http_status(:ok)
  end

  # end_game, not withdraw: withdraw/restore/unfinish/lock/unlock are gated by
  # require_superadmin! (games_controller.rb:19), a separate filter this task
  # does not touch. end_game is on ensure_author's list (:16) and already
  # calls record_admin_action("end_game", @game) if acting_as_operator?(@game)
  # (:96) -- the pairing this example is meant to prove.
  it "audits an operator acting on a gated game they did not author" do
    game = gated_game
    sign_in(operator)

    expect { post end_game_game_path(game) }.to change { AdminAction.count }.by(1)
    expect(AdminAction.newest_first.first.action).to eq("end_game")
  end
end
