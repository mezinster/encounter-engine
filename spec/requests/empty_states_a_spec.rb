require "rails_helper"

# Designed empty states for the lists people browse (E1 polish, task 8). Each
# site is checked both ways: empty shows the literal Russian title and drops
# the table/list; populated keeps the table/list and shows no empty state.
# Russian is pinned literally -- include(I18n.t(...)) would pass on a missing key.
describe "empty states on browsing lists", type: :request do
  let(:forbidden) do
    [
      "не используется", "photo.jpg", "(принять)", "(отказать)",
      "Добавить новое задание", "Начать тестирование", "Предстоит игра"
    ]
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def superadmin
    u = create_user
    u.update!(:is_superadmin => true)
    u
  end

  def expect_clean_copy(scope = response.body)
    forbidden.each { |s| expect(scope).not_to include(s) }
  end

  describe "games list" do
    it "shows a card instead of the table when no game is listed" do
      get games_path

      expect(page.css(".empty-state .empty-state-title").map(&:text)).to include("Игр пока нет")
      expect(response.body).to include("Здесь появятся игры, как только их опубликуют.")
      expect(page.css("table.table--cards")).to be_empty
      expect_clean_copy
    end

    it "keeps the table when there is a game" do
      create_game(:author => create_user)

      get games_path

      expect(page.css("table.table--cards")).not_to be_empty
      expect(page.css(".empty-state")).to be_empty
    end
  end

  describe "dashboard" do
    let(:user) { create_user }
    before { sign_in(user) }

    it "keeps #mygames and #coming and fills each with its own empty state" do
      get dashboard_path

      expect(page.css("#mygames")).not_to be_empty
      expect(page.css("#coming")).not_to be_empty
      expect(page.css("#mygames .empty-state-title").map(&:text)).to eq(["Игр пока нет"])
      expect(page.css("#mygames .empty-state p").map(&:text)).to include("Созданные вами игры появятся здесь.")
      expect(page.css("#mygames .empty-state-action")).to be_empty
      expect(page.css("#mygames a.btn").size).to eq(1)
      expect(page.css("#coming .empty-state-line").map(&:text)).to eq(["Предстоящих игр нет"])
      expect(response.body).to include("Завершённых игр нет")
      expect(response.body).to include("Команды ещё не зарегистрированы")
      expect(response.body).to include("Заявок пока нет")
      expect_clean_copy
    end

    it "words the aggregate applications card without a per-game sentence" do
      get dashboard_path

      card = page.css("fieldset").find { |f| f.css(".empty-state-title").map(&:text).include?("Заявок пока нет") }
      expect(card).not_to be_nil
      expect(card.text).not_to include("на эту игру")
      expect(card.css(".empty-state p")).to be_empty
    end

    it "shows the lists, not the empty states, when there is data" do
      game = create_game(:author => user)

      get dashboard_path

      expect(page.css("#mygames table.table--cards")).not_to be_empty
      expect(page.css("#mygames .empty-state")).to be_empty
      expect(page.css("#coming ul.game-list li")).not_to be_empty
      expect(page.css("#coming .empty-state-line")).to be_empty
      expect(response.body).to include(game.name)
    end
  end

  describe "teams list" do
    it "offers a signed-in user with no team a way to create one" do
      sign_in(create_user)

      get teams_path

      expect(page.css(".empty-state-title").map(&:text)).to include("Команд пока нет")
      expect(page.at_css(".empty-state h2.empty-state-title")).to be_present
      expect(response.body).to include("Создайте первую или дождитесь приглашения капитана.")
      expect(page.css(".empty-state a.empty-state-action").map(&:text)).to eq(["Создать команду"])
      expect(page.css("table.table--cards")).to be_empty
      expect_clean_copy
    end

    it "offers a guest no action" do
      get teams_path

      expect(page.css(".empty-state-title").map(&:text)).to include("Команд пока нет")
      expect(page.at_css(".empty-state h2.empty-state-title")).to be_present
      expect(page.css(".empty-state-action")).to be_empty
      expect(response.body).not_to include("Создать команду")
    end

    # M6: the sentence asks the reader to create a team, so it renders only
    # where the create link does.
    it "tells a guest no sentence they cannot act on" do
      get teams_path

      expect(page.css(".empty-state p")).to be_empty
      expect(response.body).not_to include("Создайте первую или дождитесь приглашения капитана.")
    end

    it "never offers a team member the create link" do
      member = create_user
      team = create_team(:captain => member)
      expect(team).to be_persisted
      sign_in(member)
      get teams_path
      expect(page.css(".empty-state")).to be_empty
      expect(response.body).not_to include("Создать команду")

    end

    it "hides the create link from a member even on an empty list" do
      # A real member, but the index query is stubbed empty: a genuine member
      # always makes the list non-empty, so this is the only way to reach the gate.
      member = create_user
      create_team(:captain => member)
      allow(Team).to receive(:includes).and_return(Team.none)
      sign_in(member)

      get teams_path

      expect(page.css(".empty-state-title").map(&:text)).to include("Команд пока нет")
      expect(page.css(".empty-state-action")).to be_empty
      expect(response.body).not_to include("Создать команду")
      expect(response.body).not_to include("Создайте первую или дождитесь приглашения капитана.")
    end

    it "keeps the table when there are teams" do
      create_team(:captain => create_user)

      get teams_path

      expect(page.css("table.table--cards")).not_to be_empty
      expect(page.css(".empty-state")).to be_empty
    end
  end

  describe "an author's game page" do
    let(:author) { create_user }
    let(:game)   { create_game(:author => author) }
    before { sign_in(author) }

    it "says there are no levels and no applications, without a second add button" do
      get game_path(game)

      titles = page.css(".empty-state-title").map(&:text)
      expect(titles).to include("Уровней пока нет", "Заявок пока нет")
      expect(response.body).to include("Добавьте первый уровень, чтобы в игру можно было играть.")
      expect(page.css(".empty-state p").map(&:text)).to include("Заявки команд на эту игру появятся здесь.")
      expect(page.css(".empty-state-action")).to be_empty
      # The page's own add-level button legitimately carries a frozen string;
      # what this task adds (the cards) must not.
      expect_clean_copy(page.css(".empty-state").text)
    end

    it "keeps the level list when there is a level" do
      create_level(:game => game)

      get game_path(game)

      expect(page.css("ul.game-list li")).not_to be_empty
      expect(page.css(".empty-state-title").map(&:text)).not_to include("Уровней пока нет")
    end

    it "keeps the applications list when a team has applied" do
      team = create_team(:captain => create_user)
      create_game_entry(:game => game, :team => team, :status => "new")

      get game_path(game)

      expect(page.css(".empty-state-title").map(&:text)).not_to include("Заявок пока нет")
      expect(response.body).to include(team.name)
    end
  end

  describe "a level's hints" do
    let(:author) { create_user }
    let(:game)   { create_game(:author => author) }
    let(:level)  { create_level(:game => game) }
    before { sign_in(author) }

    it "shows the existing sentence as an empty-state line" do
      get game_level_path(game, level)

      expect(page.css(".empty-state-line").map(&:text)).to include("Подсказок нет")
    end

    it "lists a hint when there is one" do
      create_hint(:level => level, :text => "Look under the bridge")

      get game_level_path(game, level)

      expect(response.body).to include("Look under the bridge")
      expect(page.css(".empty-state-line").map(&:text)).not_to include("Подсказок нет")
    end
  end

  describe "answers" do
    let(:author)   { create_user }
    let(:game)     { create_game(:author => author) }
    let(:level)    { create_level(:game => game) }
    let(:question) { level.questions.first }
    before { sign_in(author) }

    it "shows a line instead of the table when no answer is left" do
      Answer.where(:question_id => question.id).delete_all

      get game_level_question_answers_path(game, level, question)

      expect(page.css(".empty-state-line").map(&:text)).to include("Ответов нет")
      expect(page.css(".table-wrap table")).to be_empty
    end

    it "keeps the table when there are answers" do
      get game_level_question_answers_path(game, level, question)

      expect(page.css(".table-wrap table tr")).not_to be_empty
      expect(page.css(".empty-state-line")).to be_empty
    end
  end

  describe "admin consoles" do
    before { sign_in(superadmin) }

    it "says there are no games" do
      get admin_games_path
      expect(page.css(".empty-state-line").map(&:text)).to eq(["Игр нет"])
      expect(page.css("table.table--cards")).to be_empty
    end

    it "keeps the games table when there is a game" do
      create_game(:author => create_user)
      get admin_games_path
      expect(page.css("table.table--cards")).not_to be_empty
      expect(page.css(".empty-state-line")).to be_empty
    end

    it "says there are no teams" do
      get admin_teams_path
      expect(page.css(".empty-state-line").map(&:text)).to eq(["Команд нет"])
      expect(page.css("table.table--cards")).to be_empty
    end

    it "keeps the teams table when there is a team" do
      create_team(:captain => create_user)
      get admin_teams_path
      expect(page.css("table.table--cards")).not_to be_empty
      expect(page.css(".empty-state-line")).to be_empty
    end

    it "says there are no audited actions" do
      get admin_audit_index_path
      expect(page.css(".empty-state-line").map(&:text)).to eq(["Действий пока нет"])
      expect(page.css("table.table--cards")).to be_empty
    end

    it "keeps the audit table once an action was recorded" do
      game = create_game(:author => create_user, :is_draft => true)
      post withdraw_game_path(game), :params => { :withdrawal_category => "other", :withdrawal_mode => "freeze" }
      get admin_audit_index_path
      expect(page.css("table.table--cards")).not_to be_empty
      expect(page.css(".empty-state-line")).to be_empty
    end

    it "says there are no applications on either entries list" do
      game = create_game(:author => create_user)
      get admin_game_entries_path(game)
      expect(page.css(".empty-state-line").map(&:text)).to eq(["Заявок нет", "Заявок нет"])
    end

    it "lists applications when there are some" do
      game = create_game(:author => create_user)
      team = create_team(:captain => create_user)
      create_game_entry(:game => game, :team => team, :status => "new")
      get admin_game_entries_path(game)
      expect(response.body).to include(team.name)
      expect(page.css(".empty-state-line").map(&:text)).to eq(["Заявок нет"])
    end
  end
end
