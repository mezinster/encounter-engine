require "rails_helper"

describe "playing a paused game", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_level(:game => game, :correct_answer => "правильно") }
  let(:passing) { create_game_passing(:level => level) }
  # create_game_passing's default team has no captain (fixtures_helper.rb's
  # create_team leaves :captain nil unless given). current_user.captain? --
  # used both by show_current_level.html.erb's exit-game link and by
  # ensure_team_captain -- dereferences team.captain.id unconditionally, so
  # an uncaptained team 500s here regardless of pausing. Every other spec
  # that signs a player in as captain sets this explicitly (see
  # spec/requests/paused_hint_seeding_spec.rb's create_team(:captain =>
  # player)); doing the same here via update! after the fact, since passing
  # (and therefore its team) must exist first.
  let(:player)  { u = create_user; u.update!(:team => passing.team); passing.team.update!(:captain => u); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    passing
    sign_in(player)
  end

  it "still shows the player their level, with the paused notice" do
    game.pause!

    get show_current_level_path(:game_id => game.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("game_passings.paused"))
    expect(response.body).to include(level.name)
  end

  # A paused game is a normal temporary state, not an authorization failure --
  # rendering it as a 401 would be both confusing and untrue.
  it "refuses an answer with a notice rather than a 401" do
    game.pause!

    post post_answer_path(:game_id => game.id), :params => { :answer => "правильно" }

    expect(response).not_to have_http_status(:unauthorized)
    expect(passing.reload.current_level).to eq(level)
  end

  it "accepts the same answer once the game resumes" do
    game.pause!
    game.reload.resume!

    post post_answer_path(:game_id => game.id), :params => { :answer => "правильно" }

    expect(passing.reload.current_level).not_to eq(level)
  end

  it "refuses to let a team quit while paused" do
    game.pause!

    get exit_game_path(:game_id => game.id)

    expect(passing.reload.exited?).to be false
  end
end
