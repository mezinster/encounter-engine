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

    it "shows the card's team count" do
      game = scheduled("Ночной Бишкек", 1.day.from_now)
      set_game_schedule!(game, :max_team_number => 20)
      create_game_entry(:game => game, :team => create_team, :status => "accepted")
      get root_path

      expect(doc.at_css(".next-game").text).to include("Команд: 1 из 20")
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

  describe "for a signed-in player" do
    let(:captain) { create_user }
    let!(:team)   { create_team(:captain => captain) }
    let!(:game)   { scheduled("Ночной Бишкек", 1.day.from_now) }

    def sign_in(user)
      put login_path, :params => { :email => user.email, :password => "1234" }
    end

    it "drops the explanation and never says Зарегистрироваться" do
      sign_in(captain)
      get root_path

      expect(response.body).not_to include("Городские игры: найди код раньше всех")
      expect(doc.at_css("#how-to-play")).to be_nil
      expect(response.body).not_to include("Проводите игры в своём городе")
      expect(response.body).not_to include("Зарегистрироваться")
      expect(doc.at_css("h1").text.strip).to eq("Ближайшие игры")
    end

    it "offers the captain the dashboard's apply button" do
      sign_in(captain)
      get root_path

      button = doc.at_css(".next-game .next-game-action button")
      expect(button.text.strip).to eq("Подать заявку на регистрацию")
      expect(button["class"].split).to include("btn", "btn--go")
    end

    it "shows an applied captain the recall control" do
      create_game_entry(:game => game, :team => team, :status => "new")
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.text).to include("Заявка подана")
      expect(action.css("button").map { |b| b.text.strip }).to include("Отозвать")
    end

    it "shows an accepted captain the decline control" do
      create_game_entry(:game => game, :team => team, :status => "accepted")
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.text).to include("Вы зарегистрированы")
      expect(action.css("button").map { |b| b.text.strip }).to include("Отказаться")
    end

    it "tells the captain when the registration deadline has passed" do
      set_game_schedule!(game, :registration_deadline => 1.hour.ago)
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.at_css(".notice").text).to include("опоздали на игру")
      expect(action.css("button")).to be_empty
      expect(doc.at_css(".next-game").text).to include("Регистрация закрыта")
    end

    it "tells the captain when the team limit is reached" do
      set_game_schedule!(game, :max_team_number => 1, :requested_teams_number => 1)
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.at_css(".notice").text).to include("превышено количество участников")
      expect(action.css("button")).to be_empty
    end

    it "offers a recalled captain the reapply control" do
      create_game_entry(:game => game, :team => team, :status => "recalled")
      sign_in(captain)
      get root_path

      expect(doc.at_css(".next-game .next-game-action button").text.strip).to eq("Подать заявку на регистрацию заново")
    end

    it "tells a member who is not the captain that the captain applies" do
      member = create_user
      team.members << member
      sign_in(member)
      get root_path

      expect(doc.at_css(".next-game .next-game-action").text).to include("Заявку подаёт капитан команды")
      expect(doc.css(".next-game button")).to be_empty
    end

    it "points a player with no team to the teams page" do
      loner = create_user
      sign_in(loner)
      get root_path

      link = doc.at_css(".next-game .next-game-action a")
      expect(link.text.strip).to eq("Создайте команду или вступите в неё, чтобы играть")
      expect(link["href"]).to eq(teams_path)
    end

    it "shows the author their own game without apply buttons" do
      sign_in(game.author)
      get root_path

      expect(doc.at_css(".next-game .next-game-action").text).to include("Вы автор игры")
      expect(doc.css(".next-game button")).to be_empty
    end

    it "shows the author who is also a captain «Вы автор игры», not the controls" do
      authored = create_game(:name => "Авторская", :author => captain)
      set_game_schedule!(authored, :starts_at => 12.hours.from_now)
      sign_in(captain)
      get root_path

      expect(doc.at_css(".next-game").text).to include("Авторская")
      expect(doc.at_css(".next-game .next-game-action").text).to include("Вы автор игры")
      expect(doc.css(".next-game button")).to be_empty
    end

    it "shows the team's status on rows" do
      later = scheduled("Тайны старого города", 2.days.from_now)
      rejected = scheduled("Зимний марафон", 3.days.from_now)
      create_game_entry(:game => later, :team => team, :status => "accepted")
      create_game_entry(:game => rejected, :team => team, :status => "rejected")
      sign_in(captain)
      get root_path

      rows = doc.css(".game-row").map { |row| row.text.squish }
      expect(rows).to include(a_string_including("Тайны старого города", "Вы зарегистрированы"))
      expect(rows).to include(a_string_including("Зимний марафон", "Заявка отклонена"))
    end

    it "says whether the team holds access to a code-gated game" do
      gated = create_game(:name => "Платная", :access_mode => "pass_required")
      create_access_pass(:game => gated, :team => team)
      sign_in(captain)
      get root_path

      row = doc.css(".game-row").find { |r| r.text.include?("Платная") }
      expect(row.text).to include("Доступ есть")
    end

    it "names the team and links its room" do
      sign_in(captain)
      get root_path

      expect(response.body).to include("«#{team.name}»")
      expect(doc.css(".home-upcoming a").map { |a| a["href"] }).to include(team_room_path)
    end
  end
end
