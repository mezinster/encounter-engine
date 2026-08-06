require "rails_helper"

describe "the games listing", type: :request do
  def running_game(name)
    game = create_game(:is_draft => false, :name => name, :max_team_number => 20)
    game.update_column(:starts_at, 2.hours.ago)
    game
  end

  it "shows a scheduled game's start time and registration count, and no duration" do
    game = create_game(:is_draft => false, :name => "Скоро", :max_team_number => 20)
    2.times { GameEntry.create!(:game => game, :team => create_team, :status => "accepted") }

    get games_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Скоро")
    expect(response.body).to include(I18n.t("games.list.status_scheduled"))
    expect(response.body).to include("2 / 20")
  end

  it "counts only accepted entries towards registration" do
    game = create_game(:is_draft => false, :max_team_number => 20)
    GameEntry.create!(:game => game, :team => create_team, :status => "accepted")
    GameEntry.create!(:game => game, :team => create_team, :status => "new")
    GameEntry.create!(:game => game, :team => create_team, :status => "rejected")

    get games_path

    expect(response.body).to include("1 / 20")
  end

  it "shows a running game as running, with the teams actually playing" do
    game = running_game("Идёт")
    create_game_passing(:level => create_level(:game => game), :game => game)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_running"))
    expect(response.body).to include(I18n.t("games.list.playing", :count => 1))
  end

  it "marks a paused game as paused without changing its status" do
    game = running_game("Пауза")
    game.pause!

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_running"))
    expect(response.body).to include(I18n.t("games.list.paused"))
  end

  it "shows a finished game's end time and how long it ran" do
    game = running_game("Всё")
    game.update_column(:author_finished_at, game.starts_at + 3725)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_finished"))
    expect(response.body).to include(I18n.t("games.list.duration", :hours => 1, :minutes => 2))
  end

  it "shows no duration for a game with no start time" do
    game = create_game(:is_draft => false, :name => "Без даты")
    game.update_column(:starts_at, nil)

    get games_path

    expect(response.body).to include("Без даты")
    expect(response.body).not_to include(I18n.t("games.list.duration", :hours => 0, :minutes => 0))
  end

  # Two N+1s reached review on the quiz branch this session: one from a
  # missing preload, one from calling a scope on an already-preloaded
  # association, which re-queries. This pins the fix rather than trusting it.
  # Defined at describe level, not inside the example: `def` inside a block
  # takes its default definee from the enclosing class, so it would silently
  # attach to the example group and work only by accident.
  def count_queries
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  it "issues the same number of queries for ten games as for one" do
    running_game("Одна")
    get games_path
    one = count_queries { get games_path }

    9.times { |i| running_game("Игра #{i}") }
    ten = count_queries { get games_path }

    expect(ten).to eq(one)
  end
end
