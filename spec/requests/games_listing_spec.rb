require "rails_helper"

describe "the games listing", type: :request do
  def running_game(name, options = {})
    game = create_game({ :is_draft => false, :name => name, :max_team_number => 20 }.merge(options))
    set_game_schedule!(game, :starts_at => 2.hours.ago)
    game
  end

  def login(user)
    post login_path, params: { email: user.email, password: "1234" }
  end

  # create_game_entry throughout, not a bare GameEntry.create!, which left
  # game_run_id NULL. The application cannot produce such a row --
  # GameEntriesController#new always passes game_run: @game.current_run, and
  # CreateGameRuns backfilled every existing one -- and it authorises nothing,
  # because every admission check reads GameEntry.of_run. This listing's counts
  # are run-scoped now (GamesHelper#game_team_counts), so a runless entry does
  # not appear in them.
  it "shows a scheduled game's start time and registration count, and no duration" do
    game = create_game(:is_draft => false, :name => "Скоро", :max_team_number => 20)
    2.times { create_game_entry(:game => game, :team => create_team, :status => "accepted") }

    get games_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Скоро")
    expect(response.body).to include(I18n.t("games.list.status_scheduled"))
    expect(response.body).to include("2 / 20")
  end

  it "counts only accepted entries towards registration" do
    game = create_game(:is_draft => false, :max_team_number => 20)
    create_game_entry(:game => game, :team => create_team, :status => "accepted")
    create_game_entry(:game => game, :team => create_team, :status => "new")
    create_game_entry(:game => game, :team => create_team, :status => "rejected")

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

  it "shows no paused marker on a game that was paused and then finished" do
    game = running_game("Пауза-Финиш")
    game.pause!
    # finish_game! never clears paused_at, and a running game fails its own
    # validations, so this is update_column, not finish_game!/update!.
    set_game_schedule!(game, :author_finished_at => Time.now)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_finished"))
    expect(response.body).not_to include(I18n.t("games.list.paused"))
  end

  it "shows a finished game's end time and how long it ran" do
    game = running_game("Всё")
    set_game_schedule!(game, :author_finished_at => game.starts_at + 3725)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_finished"))
    expect(response.body).to include(I18n.t("games.list.duration", :hours => 1, :minutes => 2))
  end

  # GamesController#end_game has no started? guard (config/routes.rb), so an
  # author can end a game whose start is still in the future -- driven over
  # HTTP by the whole-branch review. The resulting interval is negative, and
  # Ruby's floor division on a negative dividend makes the rendered value
  # wrong as well as negative (-7260s would render "-3 ч 59 мин", not the
  # true "-2 ч 1 мин"). Rather than teach the arithmetic about negative
  # intervals, render nothing -- the guarded end_game behaviour itself is
  # deliberately out of scope for this fix.
  it "shows no duration when the author ends a game before its scheduled start" do
    game = create_game(:is_draft => false, :name => "Завершили раньше начала", :max_team_number => 20)
    starts_at = 1.day.from_now
    # 2h1m before the scheduled start
    set_game_schedule!(game, :starts_at => starts_at, :author_finished_at => starts_at - 7260)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_finished"))
    expect(response.body).not_to include(I18n.t("games.list.duration", :hours => -3, :minutes => 59))
    expect(response.body).not_to include(I18n.t("games.list.duration", :hours => -2, :minutes => 1))
  end

  it "counts only passings still in progress towards a running game's playing total" do
    game = running_game("Микс")
    level = create_level(:game => game)
    create_game_passing(:level => level, :game => game) # in progress
    create_game_passing(:level => level, :game => game, :finished_at => Time.now) # finished normally
    create_game_passing(:level => level, :game => game, :status => "exited", :finished_at => Time.now)
    create_game_passing(:level => level, :game => game, :status => "ended") # operator-ended, finished_at nil

    get games_path

    expect(response.body).to include(I18n.t("games.list.playing", :count => 1))
  end

  it "shows every team that took part on a finished game, not just those mid-level when it ended" do
    game = running_game("Итог")
    level = create_level(:game => game)
    create_game_passing(:level => level, :game => game) # mid-level when the author ended it
    create_game_passing(:level => level, :game => game, :finished_at => Time.now) # finished normally
    create_game_passing(:level => level, :game => game, :status => "exited", :finished_at => Time.now)
    set_game_schedule!(game, :author_finished_at => Time.now)

    get games_path

    expect(response.body).to include(I18n.t("games.list.played", :count => 3))
  end

  it "falls back to how many teams took part when a running game's teams have all finished" do
    game = running_game("Все финишировали")
    level = create_level(:game => game)
    create_game_passing(:level => level, :game => game, :finished_at => Time.now)
    create_game_passing(:level => level, :game => game, :status => "exited", :finished_at => Time.now)
    # Author has not ended the game -- it is still :running, not :finished.

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_running"))
    expect(response.body).to include(I18n.t("games.list.played", :count => 2))
    expect(response.body).not_to include(I18n.t("games.list.playing", :count => 0))
  end

  it "shows no participation line for a scheduled game nobody has entered" do
    game = create_game(:is_draft => false, :name => "Никто не записался", :max_team_number => 20)

    get games_path

    expect(response.body).to include(I18n.t("games.list.status_scheduled"))
    expect(response.body).not_to include(I18n.t("games.list.playing", :count => 0))
    expect(response.body).not_to include(I18n.t("games.list.played", :count => 0))
  end

  it "shows no duration for a game with no start time" do
    game = create_game(:is_draft => false, :name => "Без даты")
    set_game_schedule!(game, :starts_at => nil)

    get games_path

    expect(response.body).to include("Без даты")
    expect(response.body).not_to include(I18n.t("games.list.duration", :hours => 0, :minutes => 0))
  end

  # The example above constructs a :scheduled game (no author_finished_at),
  # for which game_duration_text's `case` returns nil on its own -- the
  # starts_at.nil? guard above it is dead code for that input. The guard is
  # actually load-bearing for a :finished game with nil starts_at: without
  # it, `finish - game.starts_at` raises TypeError (nil has no `-`), a 500 on
  # /games for every visitor. This reaches that line.
  it "does not 500 for a finished game with no start time on record" do
    game = create_game(:is_draft => false, :name => "Завершена без даты начала", :max_team_number => 20)
    set_game_schedule!(game, :starts_at => nil, :author_finished_at => Time.now)

    get games_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("games.list.status_finished"))
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

  # Logged out, `current_user.author_of?(game)` short-circuits and the
  # author-only action links (edit, stats, live channel, full log, end game)
  # never render -- which is the one place a per-game query could sneak in.
  # An anonymous run of this example would pass regardless of an N+1 in that
  # branch, so this runs authenticated as the games' own author, the real
  # path an operator hits every time they open their own listing.
  it "issues the same number of queries for ten games as for one, for the logged-in author" do
    author = create_user
    login(author)

    running_game("Одна", :author => author)
    get games_path
    one = count_queries { get games_path }

    9.times { |i| running_game("Игра #{i}", :author => author) }
    ten = count_queries { get games_path }

    expect(ten).to eq(one)
  end

  # GamesHelper#gated_play_status -- the batched preload behind the play
  # link/access-required cell below. A per-row AccessPass lookup would break
  # this exactly as an unpreloaded deletable? broke the admin console
  # (fd96d51): the query count must not grow with the number of gated rows.
  describe "the play link on a gated row" do
    it "shows the play link when the signed-in team holds a live pass" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      captain = create_user
      team = create_team(:captain => captain)
      create_access_pass(:game => game, :team => team)
      login(captain)

      get games_path

      expect(response.body).to include(I18n.t("shared.current_games_status.play"))
    end

    # F11: the games list links to the redemption form now, with its own
    # link-text key -- errors.no_access_pass remains a refusal message used
    # elsewhere (GamePassingsController), but this listing no longer renders it.
    it "shows the redeem-code link when the signed-in team holds no pass" do
      game = create_game(:is_draft => false, :access_mode => "pass_required")
      captain = create_user
      create_team(:captain => captain)
      login(captain)

      get games_path

      expect(response.body).to include(I18n.t("shared.current_games_status.redeem_code_link"))
    end

    it "shows the redeem-code link to a guest" do
      create_game(:is_draft => false, :access_mode => "pass_required")

      get games_path

      expect(response.body).to include(I18n.t("shared.current_games_status.redeem_code_link"))
    end

    it "does not show the message at all for a scheduled game" do
      running_game("Обычная")

      get games_path

      expect(response.body).not_to include(I18n.t("shared.current_games_status.redeem_code_link"))
    end

    it "does not grow the query count as the number of gated rows grows" do
      captain = create_user
      team = create_team(:captain => captain)
      login(captain)

      game = create_game(:is_draft => false, :access_mode => "pass_required")
      create_access_pass(:game => game, :team => team)
      one = count_queries { get games_path }

      9.times do
        g = create_game(:is_draft => false, :access_mode => "pass_required")
        create_access_pass(:game => g, :team => team)
      end
      ten = count_queries { get games_path }

      expect(ten).to eq(one)
    end
  end
end
