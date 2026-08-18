require "rails_helper"

# access_mode is operator territory (a commercially-sold game), not an
# ordinary author's -- see User#may_operate_commercial?. The control that
# sets it must both be hidden from an ordinary author's form AND refuse a
# hand-crafted POST, because permitting the param without stripping it for
# non-operators would leave the second half of that guarantee unenforced.
describe "authoring access_mode", type: :request do
  let(:author)     { create_user }
  let(:operator)   { u = create_user; u.update!(:is_operator => true); u }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def game_params(overrides = {})
    {
      :name => "Гонка №" + rand(1_000_000).to_s,
      :description => "Описание",
      :starts_at => "2099-01-01 00:00",
      :max_team_number => "2"
    }.merge(overrides)
  end

  it "does not render the access_mode control for an ordinary author" do
    sign_in(author)

    get new_game_path

    expect(response.body).not_to include("game[access_mode]")
  end

  it "renders the access_mode control for an operator" do
    sign_in(operator)

    get new_game_path

    expect(response.body).to include("game[access_mode]")
  end

  it "renders the access_mode control for a superadmin" do
    sign_in(superadmin)

    get new_game_path

    expect(response.body).to include("game[access_mode]")
  end

  it "does not gate a game created by an ordinary author, even with access_mode in the POST" do
    sign_in(author)
    name = "Обычная игра " + rand(1_000_000).to_s

    post games_path, :params => { :game => game_params(:access_mode => "pass_required", :name => name) }

    game = Game.find_by!(:name => name)
    expect(game.access_mode).to eq("scheduled")
    expect(game.pass_required?).to be false
  end

  it "lets an operator create a gated game" do
    sign_in(operator)
    name = "Операторская игра " + rand(1_000_000).to_s

    post games_path, :params => { :game => game_params(:access_mode => "pass_required", :name => name) }

    game = Game.find_by!(:name => name)
    expect(game.access_mode).to eq("pass_required")
    expect(game.pass_required?).to be true
  end

  it "lets a superadmin create a gated game" do
    sign_in(superadmin)
    name = "Игра суперадмина " + rand(1_000_000).to_s

    post games_path, :params => { :game => game_params(:access_mode => "pass_required", :name => name) }

    game = Game.find_by!(:name => name)
    expect(game.access_mode).to eq("pass_required")
  end

  it "does not let an ordinary author flip their own game to gated via update" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(author)

    put game_path(game), :params => { :game => game_params(:access_mode => "pass_required", :name => game.name) }

    expect(game.reload.access_mode).to eq("scheduled")
  end

  # ensure_author scopes an operator's authority to games that are ALREADY
  # gated (app/controllers/concerns/security_filters.rb) -- an operator
  # cannot reach the edit action on someone else's SCHEDULED game at all, so
  # the only way an operator gates a game is by authoring it themselves.
  it "lets an operator flip their OWN game to gated via update" do
    game = create_game(:author => operator, :is_draft => false)
    sign_in(operator)

    put game_path(game), :params => { :game => game_params(:access_mode => "pass_required", :name => game.name) }

    expect(game.reload.access_mode).to eq("pass_required")
  end

  it "lets a superadmin flip someone else's scheduled game to gated via update" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(superadmin)

    put game_path(game), :params => { :game => game_params(:access_mode => "pass_required", :name => game.name) }

    expect(game.reload.access_mode).to eq("pass_required")
  end
end
