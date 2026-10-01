require "rails_helper"

describe "announcements and headings", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "shows a failed login's error once, as an alert" do
    post login_path, :params => { :email => "nobody@example.com", :password => "x" }
    doc = Nokogiri::HTML(response.body)
    errors = doc.xpath("//*[contains(text(), 'Неправильный email или пароль')]")
    expect(errors.size).to eq(1)
    expect(errors.first["role"]).to eq("alert")
  end

  it "titles the standings page with a real heading" do
    author = create_user
    game = create_game(:author => author, :name => "Ночной дозор")
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    create_level(:game => game)
    sign_in(author)
    get game_stats_path(game)
    expect(Nokogiri::HTML(response.body).at_css("h1").text).to include("Ночной дозор")
  end

  it "gives the signed-in home page card an h2 under its h1" do
    user = create_user
    game = create_game(:name => "Ночной дозор")
    set_game_schedule!(game, :starts_at => 1.day.from_now)
    sign_in(user)
    get root_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("h1").text.strip).to eq("Ближайшие игры")
    expect(doc.at_css(".next-game h2")).to be_present
    expect(doc.at_css(".next-game h3")).to be_nil
  end

  it "separates «Верный код:» from the code" do
    author = create_user
    game = create_game(:author => author, :is_draft => false)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    create_level(:game => game, :correct_answer => "код1")
    sign_in(author)
    get show_full_log_path(:game_id => game.id)
    expect(Nokogiri::HTML(response.body).text).to match(/Верный код:[[:space:]]+код1/)
  end
end
