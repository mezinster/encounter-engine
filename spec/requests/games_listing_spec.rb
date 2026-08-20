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

  # The participants cell on a gated row. "N / max" and the running-vs-finished
  # choice both stop applying to a commercial game: it has no cap worth naming
  # (max_team_number defaults to 100 and gates nothing -- neither pass issuing
  # nor code redemption consults can_request?) and no run lifecycle, since
  # Game#status reports :available for the whole of its life. So it gets three
  # figures instead, and they are DERIVED, every one of them: an operator can
  # flip access_mode back and the free counters return untouched, because
  # nothing here was ever stored.
  #
  # Before this, the cell showed a gated game either "0 / 100" (born gated, no
  # entry can exist) or the stale free-era registration count it carried into
  # the conversion -- never anything about the passes it actually sold.
  describe "the participants cell on a gated row" do
    let(:team) { create_team(:captain => create_user) }
    # Built FROM a level, not `create_game` then `create_level(:game => g)`:
    # build_level's default hash calls create_game eagerly, before .merge
    # overrides it, so the second form leaves a stray extra game in the
    # listing -- which is exactly the kind of row these examples count.
    let(:level) { create_level }
    let(:game) do
      g = level.game
      g.update!(:visibility => "listed", :name => "Платная",
                :access_mode => "pass_required", :max_team_number => 100)
      g
    end

    # game_run_id nil IS the gated selector: a commercial attempt is runless by
    # design (the paid-game design, task 6), which is also why the run-scoped
    # counts beside this one cannot see it.
    def gated_attempt(team, attrs = {})
      pass = create_access_pass(:game => game, :team => team)
      GamePassing.create!({ :team => team, :game => game, :game_run => nil,
                            :access_pass => pass,
                            :current_level => game.levels.first }.merge(attrs))
    end

    it "counts the passes issued" do
      3.times { create_access_pass(:game => game, :team => create_team) }

      get games_path

      expect(response.body).to include(I18n.t("games.list.passes_issued", :count => 3))
    end

    # "Currently holds access", not "was ever handed one": a revoked pass is an
    # entitlement the operator took back.
    it "leaves a revoked pass out of the issued figure" do
      create_access_pass(:game => game, :team => create_team)
      revoked = create_access_pass(:game => game, :team => create_team)
      revoked.update!(:revoked_at => Time.now)

      get games_path

      expect(response.body).to include(I18n.t("games.list.passes_issued", :count => 1))
    end

    it "counts an attempt in progress as playing" do
      gated_attempt(team)

      get games_path

      expect(response.body).to include(I18n.t("games.list.playing", :count => 1))
    end

    # COMPLETED, not merely finished -- finished_at set and not exited, the same
    # pair Game#pass_standings sorts and the same pair AccessPass#spent? reduces
    # to. A team that quit is in neither figure, and that is deliberate: the two
    # lines of this cell have never claimed a subset relation.
    it "counts a completed attempt as finished, and a quit as neither" do
      gated_attempt(team, :finished_at => Time.now)
      gated_attempt(create_team, :finished_at => Time.now, :status => "exited")

      get games_path

      expect(response.body).to include(I18n.t("games.list.completed", :count => 1))
      expect(response.body).not_to include(I18n.t("games.list.playing", :count => 1))
    end

    # Peers, both counting attempts, so they share a line separated by a
    # middot -- unlike the cap-and-participation pair on a scheduled row, which
    # stays on two lines precisely so it claims no relation between them.
    it "joins the two attempt figures when both are non-zero" do
      gated_attempt(team)
      gated_attempt(create_team, :finished_at => Time.now)

      get games_path

      expect(response.body).to include(
        "#{I18n.t('games.list.playing', :count => 1)} · #{I18n.t('games.list.completed', :count => 1)}"
      )
    end

    # 0 issued is informative for an operator -- nobody has bought yet -- so it
    # renders. The other two suppress at zero, exactly as
    # game_participation_text already does for a scheduled row.
    it "shows a zero issued figure but suppresses the other two" do
      game

      get games_path

      expect(response.body).to include(I18n.t("games.list.passes_issued", :count => 0))
      expect(response.body).not_to include(I18n.t("games.list.playing", :count => 0))
      expect(response.body).not_to include(I18n.t("games.list.completed", :count => 0))
    end

    it "drops the registration cap, which gates nothing on a paid game" do
      game

      get games_path

      expect(response.body).not_to include("0 / 100")
    end

    # The whole point of deriving rather than storing. Nothing below is undone
    # on the way back -- entries, requested_teams_number and run-scoped
    # passings are all untouched by a conversion, so the original cell returns.
    it "returns the free counters when the game is converted back" do
      registered = create_team(:captain => create_user)
      create_game_entry(:game => game, :team => registered, :status => "accepted")
      game.reserve_place_for_team!
      gated_attempt(team)

      game.update!(:access_mode => "scheduled")

      get games_path

      expect(response.body).to include("1 / 100")
      expect(response.body).not_to include(I18n.t("games.list.passes_issued", :count => 1))
    end

    it "does not grow the query count as the number of gated rows grows" do
      gated_attempt(team)
      one = count_queries { get games_path }

      9.times do
        other = create_game(:is_draft => false, :access_mode => "pass_required")
        create_access_pass(:game => other, :team => create_team)
      end
      ten = count_queries { get games_path }

      expect(ten).to eq(one)
    end

    # The guard that keeps the new queries off every listing that has no gated
    # row at all -- the same shape gated_play_status uses, and what keeps the
    # flat-count examples above honest.
    it "issues no pass query at all for a listing with no gated row" do
      running_game("Обычная")
      without_gated = count_queries { get games_path }

      game
      with_gated = count_queries { get games_path }

      expect(with_gated).to be > without_gated
    end
  end
end
