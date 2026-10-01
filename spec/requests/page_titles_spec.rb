require "rails_helper"

describe "browser titles", type: :request do
  let(:author) { create_user }
  let(:game)   { g = create_game(:author => author, :name => "Ночной дозор"); set_game_schedule!(g, :starts_at => 1.hour.ago); g }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def title
    Nokogiri::HTML(response.body).at_css("title").text
  end

  it "keeps the bare site name on the home page" do
    get root_path
    expect(title).to eq("Активные городские игры")
  end

  it "titles a guest page with the page and the site" do
    get teams_path
    expect(title).to eq("Команды · Активные городские игры")
  end

  it "titles an operator screen with page, game and site" do
    create_level(:game => game)
    sign_in(author)
    get game_stats_path(game)
    expect(title).to eq("Турнирная таблица — Ночной дозор · Активные городские игры")
  end

  it "titles the game page with the game and the site" do
    sign_in(author)
    get game_path(game)
    expect(title).to eq("Ночной дозор · Активные городские игры")
  end

  it "titles the login page" do
    get login_path
    expect(title).to eq("Вход · Активные городские игры")
  end
end
