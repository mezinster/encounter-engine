require "rails_helper"

# Superadmin revival of an ended game -- the reverse of end_game, mirroring
# withdraw/restore. Design: docs/superpowers/specs/
# 2026-08-08-superadmin-unfinish-design.md. Ending a game was a one-way door
# (nothing in the UI clears author_finished_at); production repair required a
# console write (game 4, 2026-08-08).
describe "reviving an ended game", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.finish_game!
    g
  end

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  # create_user sets the password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "can be revived by a superadmin, who is audited" do
    sign_in(superadmin)
    post unfinish_game_path(game)

    expect(game.reload.author_finished?).to be false
    expect(response).to redirect_to(admin_games_path)
    action = AdminAction.order(:id).last
    expect(action.action).to eq("unfinish")
    expect(action.target_id).to eq(game.id)
  end

  it "cannot be revived by its own author" do
    sign_in(author)
    post unfinish_game_path(game)
    expect(game.reload.author_finished?).to be true
  end

  it "cannot be revived by an anonymous visitor" do
    post unfinish_game_path(game)
    expect(game.reload.author_finished?).to be true
  end

  # Pins the design's out-of-scope decision: revival touches only the game.
  # Teams marked "ended" stay ended until an operator reinstates each one
  # through the existing intervention (GamePassing#reinstate!), which also
  # resets the level clock -- a blanket un-end here would skip that.
  it "leaves ended team passings ended" do
    passing = create_game_passing(:level => create_level(:game => game))
    passing.end!

    sign_in(superadmin)
    post unfinish_game_path(game)

    expect(passing.reload.status).to eq("ended")
  end
end
