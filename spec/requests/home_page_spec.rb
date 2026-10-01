require "rails_helper"

# The home page. Literal Russian is pinned rather than I18n.t(...), which
# would also pass with a key missing.
describe "the home page", type: :request do
  let(:doc) { Nokogiri::HTML(response.body) }

  def scheduled(name, at)
    game = create_game(:name => name)
    set_game_schedule!(game, :starts_at => at)
    game
  end

  describe "for a guest" do
    it "explains the game, shows the next game, and keeps one filled button" do
      scheduled("Ночной Бишкек", 1.day.from_now)
      get root_path

      expect(response.body).to include("Городские игры: найди код раньше всех")
      expect(doc.css(".btn--go").size).to eq(1)
      expect(doc.at_css(".btn--go").text.strip).to eq("Зарегистрироваться")
      expect(doc.at_css(".next-game").text).to include("Ночной Бишкек")
      expect(doc.at_css(".next-game").text).to include("Регистрация открыта")
      expect(doc.at_css("#how-to-play")).to be_present
      expect(response.body).to include("Проводите игры в своём городе")
    end

    it "keeps the frozen anchors" do
      get root_path

      link = doc.css("a").find { |a| a.text.strip == "Список игр" }
      expect(link["href"]).to eq(games_path)
      expect(doc.css("a[href='#{dashboard_path}']")).to be_empty
      expect(response.body).not_to include("Вы не авторизованы")
    end

    it "shows an empty state, still with the games-list link, when nothing is upcoming" do
      get root_path

      expect(response.body).to include("Сейчас игр не запланировано")
      expect(doc.css("a").map { |a| a.text.strip }).to include("Список игр")
    end

    it "lists a running game first, tagged as happening now" do
      running = create_game(:name => "Идущая")
      set_game_schedule!(running, :starts_at => 1.hour.ago)
      scheduled("Будущая", 1.day.from_now)
      get root_path

      first_row = doc.at_css(".game-row")
      expect(first_row.text).to include("Идущая")
      expect(first_row.text).to include("Идёт сейчас")
    end

    it "says an undated game has no start date yet" do
      undated = create_game(:name => "Без даты")
      set_game_schedule!(undated, :starts_at => nil)
      get root_path

      expect(doc.at_css(".next-game").text).to include("Дата начала игры ещё не назначена")
    end

    it "links how-to-play and organizers into the Russian manual's chapters" do
      get root_path

      expect(doc.css("a").map { |a| a["href"] }).to include("#{manual_path}#игроку", "#{manual_path}#автору-игры")
    end
  end
end
