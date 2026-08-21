# Builds and removes a load-test cohort. See
# docs/superpowers/specs/2026-08-21-load-testing-design.md.
#
# Every account this creates is a real row in a real database, with a real
# password, and on run night that database is production. Three properties are
# therefore structural rather than operational discipline: the password is
# generated per run and never constant, the addresses are unroutable, and
# seeding refuses while a previous cohort is still present so a forgotten
# teardown blocks the next run instead of silently doubling up.
#
# A FOURTH property was added on 2026-08-21, after an incident: a superadmin
# pressed "Create cohort" twice, seven seconds apart, because the first
# request gave no feedback for ten minutes. Both requests seeded 120 teams
# concurrently -- #existing_cohort below reads COMMITTED rows, and ten
# minutes of seeding inside one transaction commits nothing until the very
# end, so both requests saw an empty database and both proceeded. #seed! now
# takes a session-scoped lock (#with_seed_lock) around the whole method,
# which is invisible to MVCC in exactly the way a row count is not.
require "zlib"

module LoadTest
  class Seeder
    class CohortPresent < StandardError; end
    # Distinct from CohortPresent on purpose: CohortPresent means a cohort
    # already exists (committed rows); AlreadySeeding means one is still
    # being BUILT (nothing committed yet) -- the two incidents that produced
    # them are different, and conflating the message would send an operator
    # looking for a cohort that has no rows to find.
    class AlreadySeeding < StandardError; end

    EMAIL_DOMAIN     = "loadtest.invalid".freeze
    MEMBERS_PER_TEAM = 3

    # Shared by game_name (which writes it) and status (which reads the cohort
    # id back off it). A literal in two places is one edit away from silently
    # breaking status.
    GAME_NAME_PREFIX = "НЕ ИГРА — нагрузочный тест ".freeze

    # A single, fixed key: only one cohort is ever seeded at a time, so there
    # is nothing to namespace by. crc32 of a literal name rather than a bare
    # magic integer, so the key's origin is legible without this comment.
    # PostgreSQL requires advisory lock ids to fit a signed 64-bit integer;
    # crc32 is 32 bits, comfortably inside that.
    LOCK_KEY = Zlib.crc32("load_test_seeder").freeze

    # sqlite (development, test -- production is always Postgres, see
    # LoadTest.live?) has no real advisory lock: supports_advisory_locks? is
    # false and the adapter's own get_advisory_lock is a no-op (returns nil,
    # not true -- see AbstractAdapter). Rails.cache is :memory_store and
    # process-global here (see CLAUDE.md), which is an adequate single-process
    # stand-in for local development -- explicit, rather than silently
    # skipping locking altogether on the adapter that dev and CI both run on.
    LOCAL_LOCK_CACHE_KEY = "load_test:seeding".freeze

    # Read and cleared by Admin::LoadTestsController#show. Written by the
    # background thread the controller spawns when #seed! raises -- see the
    # controller's own comment for why a thread cannot fall back to a flash.
    # Process-local and does NOT survive a restart; that is acceptable
    # because the durable signal that something went wrong is that no cohort
    # appears, not this message.
    ERROR_CACHE_KEY = "load_test:last_error".freeze

    class << self
      # Explicit deletion in dependency order, NOT a cascade. See the comment
      # on the teardown spec: GameRun has_many :passings carries no
      # dependent: option deliberately, so destroying the game leaves the
      # passings behind. Anything relying on cascades here would leave rows in
      # production and report success. Log (Game has_many :logs, also no
      # dependent: option) and the ledger/social rows attached to the users and
      # teams themselves (PointTransaction, Invitation, TeamJoinRequest,
      # GameLocalePreference) are the same trap and get the same explicit
      # treatment.
      def teardown!(cohort_id)
        present = status[:cohort_id]
        unless present == cohort_id
          raise ArgumentError,
                "cohort #{cohort_id.inspect} is not the cohort present (#{present.inspect})"
        end

        users = User.where("email LIKE ?", "%@#{EMAIL_DOMAIN}")
        games = Game.where(:author_id => users.select(:id))
        runs  = GameRun.where(:game_id => games.select(:id))

        # Ids are materialised NOW, before the detach below, and the teams are
        # deleted through `Team.where(:id => team_ids)` rather than through a
        # relation. A relation like `Team.where(:id => users.select(:team_id))`
        # is lazy: its subquery reads users.team_id, and `update_all` below sets
        # exactly that column to NULL, so by the time delete_all ran it would
        # match nothing. The teams would survive in production and only the
        # row-count example would notice.
        team_ids = users.pluck(:team_id).compact.uniq
        game_ids = games.pluck(:id)

        removed = 0
        ActiveRecord::Base.transaction do
          removed += PointTransaction.where(:team_id => team_ids).delete_all
          # Logs are the largest table a run writes -- one per answer POST --
          # and Game#logs carries no dependent: option, matching game_passings.
          # Deleted here, before the games are destroyed, by the same game_ids
          # already materialised above.
          removed += Log.where(:game_id => game_ids).delete_all
          removed += GamePassing.where(:game_run_id => runs.select(:id)).delete_all
          removed += GameEntry.where(:game_run_id => runs.select(:id)).delete_all
          removed += TestAdmission.where(:game_run_id => runs.select(:id)).delete_all
          removed += AccessPass.where(:game_id => game_ids).delete_all
          # Invitation/TeamJoinRequest are keyed by EITHER a user or a team on
          # either side (for_user_id/to_team_id, user_id/team_id), so both
          # sides of the cohort have to be checked -- a seeded user invited by
          # an outsider, or an outsider's request against a seeded team, is
          # exactly as real as the reverse. Users' ids, unlike their team_id,
          # are never mutated by this method, so reading them lazily off
          # `users` here is safe -- the row-count example would tell us if it
          # were not.
          removed += Invitation.where(:for_user_id => users.select(:id))
                                .or(Invitation.where(:to_team_id => team_ids)).delete_all
          removed += TeamJoinRequest.where(:user_id => users.select(:id))
                                    .or(TeamJoinRequest.where(:team_id => team_ids)).delete_all
          removed += GameLocalePreference.where(:user_id => users.select(:id)).delete_all
          # Detach before deleting the teams so users.team_id never dangles
          # even if a later delete raises and the transaction unwinds midway.
          users.update_all(:team_id => nil)
          removed += Team.where(:id => team_ids).delete_all
          # game.destroy!, not delete_all: levels/questions/answers/hints/runs/
          # game_entries/access_codes hang off the game by dependent: :destroy
          # and there is no FK to cascade here.
          Game.where(:id => game_ids).each { |game| game.destroy! ; removed += 1 }
          removed += users.delete_all
        end
        removed
      end

      # The cohort id comes from the seeded GAME's name, never from a nickname.
      # Recovering it from a nickname needs a pattern, and every pattern is
      # wrong for some id: /\A(lt-[^-]+-[^-]+)-/ reads the specs' "lt-test-a"
      # correctly and turns the rake task's own "lt-2026-08-21-ab" into
      # "lt-2026-08", because the date's hyphens eat the pattern. A spec using
      # only the short form stays green while the console misreports. The game
      # name is a fixed prefix followed by the id verbatim -- nothing to parse.
      def status
        users = User.where("email LIKE ?", "%@#{EMAIL_DOMAIN}")
        game  = Game.where("name LIKE ?", "#{GAME_NAME_PREFIX}%").order(:id).first
        { :cohort_id => game && game.name.delete_prefix(GAME_NAME_PREFIX),
          :users     => users.count,
          :seeding   => seeding? }
      end

      # True while a seed is in progress anywhere -- this process or another
      # -- WITHOUT holding the lock ourselves for longer than an instant. A
      # committed-row check cannot answer this (see the class comment); the
      # lock can, because it is held for the FULL duration of #seed!, not
      # just its final commit.
      #
      # The Postgres branch is a peek, not a hold: attempt the lock, and if
      # we get it, nobody else has it, so release immediately and report
      # false. If we don't get it, someone else holds it -- report true
      # without having taken anything.
      def seeding?
        conn = ActiveRecord::Base.connection
        return Rails.cache.read(LOCAL_LOCK_CACHE_KEY).present? unless conn.supports_advisory_locks?

        if conn.get_advisory_lock(LOCK_KEY)
          conn.release_advisory_lock(LOCK_KEY)
          false
        else
          true
        end
      end

      # Force-releases a seeding lock left behind by a killed process or
      # thread -- the same shape of problem TranslationRun.sweep_stale!
      # exists for, except there is no row to mark FAILED here: the lock
      # itself IS the state, so there is nothing to sweep on a timer, only
      # something to release on request. See docs/runbooks/load-test.md.
      #
      # On sqlite this is just clearing the process-local flag. On Postgres a
      # session-scoped advisory lock cannot be released from a DIFFERENT
      # session than the one that took it -- pg_advisory_unlock only works
      # inside the owning session -- so the only way to force it loose from
      # here is to end that session. pg_locks records which backend PID holds
      # it; pg_advisory_lock(key)'s single-bigint form is stored there as
      # classid = key >> 32, objid = key & 0xffffffff (documented Postgres
      # behaviour, not this application's invention). Neither suite runs
      # against a real Postgres server (see CLAUDE.md's "Neither suite covers
      # config/environments/production.rb" note for the same shape of gap),
      # so this is unexercised by either -- verify with `bin/rails
      # load_test:status` after using it.
      def force_unlock!
        conn = ActiveRecord::Base.connection
        return Rails.cache.delete(LOCAL_LOCK_CACHE_KEY) unless conn.supports_advisory_locks?

        conn.execute(<<~SQL.squish)
          SELECT pg_terminate_backend(l.pid)
          FROM pg_locks l
          WHERE l.locktype = 'advisory' AND l.granted
            AND ((l.classid::bigint << 32) | l.objid::bigint) = #{LOCK_KEY}
        SQL
      end
    end

    attr_reader :cohort_id

    # base_url defaults through LoadTest.resolve_base_url, not a bare
    # ENV.fetch -- that method is the ONE place both seeding doors' fallback
    # lives (see its own comment for the incident this fixes and the
    # LOAD_TEST_BASE_URL -> APP_HOST -> localhost precedence). The console
    # (Admin::LoadTestsController#seed) never hits this default: it always
    # passes `request.base_url`, which is strictly better information than
    # anything derivable from ENV, so don't "simplify" that call site into
    # routing through this fallback too.
    def initialize(source_game:, teams:, cohort_id:, base_url: nil)
      @source_game = source_game
      @teams       = Integer(teams.to_s, 10)
      @cohort_id   = cohort_id
      @base_url    = base_url || LoadTest.resolve_base_url
    end

    def seed!
      # The COHORT ID, not the e-mail existing_cohort returns below -- this
      # message reaches an operator (rake stdout, or the console's flash via
      # a t() key keyed off the exception class, never this string directly),
      # and an e-mail local part built from a random hex nickname tells them
      # nothing they can act on. status[:cohort_id] is the same value the
      # rake teardown command and the console both already show.
      raise CohortPresent, "cohort #{self.class.status[:cohort_id]} still present" if existing_cohort

      with_seed_lock do
        ActiveRecord::Base.transaction do
          author = create_account("author")
          game   = GameCloner.new(@source_game).call(:name => game_name, :author => author)
          run    = open_run(game)
          teams  = Array.new(@teams) { |i| build_team(game, run, i) }

          manifest(game, run, teams)
        end
      end
    end

    private

    # See the class comment: a committed-row check cannot see a seed already
    # in flight, because nothing is committed until this whole method's
    # transaction finishes. A session-scoped advisory lock can, because it is
    # held for the full duration below, not just the final commit.
    #
    # Non-blocking on purpose (get_advisory_lock is pg_try_advisory_lock, not
    # pg_advisory_lock): a second concurrent request must be REFUSED
    # immediately, not queued to wait ten minutes behind the first -- that
    # would just move the "ten minutes with no feedback" incident from
    # "silently doubled up" to "silently queued", not fix it.
    #
    # Released in ensure: a Postgres advisory lock is bound to the SESSION
    # (the connection), and returning the connection to the pool does not end
    # the session -- a lock leaked here by an exception would block every
    # future seed until the process restarts. See ::force_unlock! for the
    # recovery if that ever happens anyway.
    def with_seed_lock
      conn = ActiveRecord::Base.connection

      unless conn.supports_advisory_locks?
        raise AlreadySeeding, "another seed is already in progress" if
          Rails.cache.read(LOCAL_LOCK_CACHE_KEY)

        Rails.cache.write(LOCAL_LOCK_CACHE_KEY, true)
        begin
          return yield
        ensure
          Rails.cache.delete(LOCAL_LOCK_CACHE_KEY)
        end
      end

      raise AlreadySeeding, "another seed is already in progress" unless
        conn.get_advisory_lock(LOCK_KEY)

      begin
        yield
      ensure
        conn.release_advisory_lock(LOCK_KEY)
      end
    end

    def game_name
      "#{GAME_NAME_PREFIX}#{@cohort_id}"
    end

    def prefix
      "#{@cohort_id}-"
    end

    def existing_cohort
      User.where("email LIKE ?", "%@#{EMAIL_DOMAIN}").limit(1).pluck(:email).first
    end

    # One password for the whole cohort: k6 holds it per VU and the cohort is
    # deleted within hours. Generated per run, never written to the repository.
    def password
      @password ||= SecureRandom.alphanumeric(32)
    end

    # Hashed ONCE for the whole cohort, not once per account. bcrypt's cost
    # factor makes a single hash deliberately expensive (that is the point of
    # bcrypt), and #password above is the same value for all 361 accounts a
    # 120-team cohort creates -- so hashing it 361 times, once per
    # User.create!, was recomputing one identical digest 361 times over. That
    # was the entire ten minutes of the 2026-08-21 incident (see the class
    # comment): #create_account below now assigns this digest directly
    # instead of the plaintext, so User's before_save encrypt_password
    # callback (which only runs `if: -> { password.present? }`) never fires.
    #
    # This does NOT weaken the load test. The cost factor is baked into the
    # stored digest string itself, not recomputed at read time, so
    # User#authenticate still performs a full-cost bcrypt VERIFY on every
    # login during the actual k6 run -- the login stampede the test exists to
    # measure is untouched. Only the one-time setup cost of BUILDING the
    # cohort changes.
    def password_digest
      @password_digest ||= BCrypt::Password.create(password)
    end

    def create_account(label)
      nickname = "#{prefix}#{label}-#{SecureRandom.hex(4)}"
      User.create!(:nickname        => nickname,
                   :email           => "#{nickname}@#{EMAIL_DOMAIN}",
                   :password_digest => password_digest)
    end

    # starts_at in the PAST: GamePassingsController refuses play with
    # game.not_started unless viewing_a_started_run?, so a run seeded with a
    # future date is seeded unplayable.
    def open_run(game)
      run = game.runs.order(:ordinal).last || game.runs.create!(:ordinal => 1)
      run.update!(:starts_at       => 1.hour.ago,
                  :max_team_number => @teams + 10,
                  :is_testing      => true,
                  :test_token      => SecureRandom.hex(16))
      run
    end

    def build_team(game, run, index)
      captain = create_account("t#{index}-captain")
      members = Array.new(MEMBERS_PER_TEAM - 1) { |m| create_account("t#{index}-m#{m}") }
      team    = Team.create!(:name => "#{prefix}team-#{index}", :captain => captain)
      ([ captain ] + members).each { |u| u.update!(:team_id => team.id) }

      # TestAdmission, not GameEntry: an is_testing run authorises through
      # `return if test_admission` in GamePassingsController, a separate branch
      # from the GameEntry one. user_id stays NULL so the admission is
      # team-wide, which the unique index permits.
      TestAdmission.create!(:game_run_id => run.id, :team_id => team.id)

      level = level_for(game, index)
      GamePassing.create!(:game_id                  => game.id,
                          :team_id                  => team.id,
                          :game_run_id              => run.id,
                          :current_level_id         => level.id,
                          :current_level_entered_at => Time.now)

      # level_id is the team's STARTING level -- correctness in the app is
      # per-level (GamePassing#check_answer! matches through
      # current_level.find_question_by_answer), and this is what lets k6's
      # pickCode() draw a "correct" answer from the right level's codes
      # instead of the whole game's, which is off by roughly the level
      # count. It drifts as the team actually answers correctly and advances
      # -- acceptable, and much closer than not tracking level at all.
      { :email => captain.email, :password => password, :team_id => team.id,
        :level_id => level.id }
    end

    # Varied depth, not decoration: AnsweredQuestionsCoder re-serialises the
    # whole answered_questions blob on every accepted answer, so the write gets
    # more expensive the further a team has progressed. Starting everyone at
    # level 1 confines the test to the cheap end of that curve.
    def level_for(game, index)
      levels = game.levels.order(:position).to_a
      levels[index % levels.size]
    end

    def manifest(game, run, teams)
      { :cohort_id => @cohort_id,
        :game_id   => game.id,
        :run_id    => run.id,
        :base_url  => @base_url,
        :teams     => teams,
        :codes     => game.levels.order(:position).each_with_object({}) { |level, acc|
          acc[level.id.to_s] = level.answers.map(&:value)
        } }
    end
  end
end
