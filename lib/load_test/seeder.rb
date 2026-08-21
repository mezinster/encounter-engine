# Builds and removes a load-test cohort. See
# docs/superpowers/specs/2026-08-21-load-testing-design.md.
#
# Every account this creates is a real row in a real database, with a real
# password, and on run night that database is production. Three properties are
# therefore structural rather than operational discipline: the password is
# generated per run and never constant, the addresses are unroutable, and
# seeding refuses while a previous cohort is still present so a forgotten
# teardown blocks the next run instead of silently doubling up.
module LoadTest
  class Seeder
    class CohortPresent < StandardError; end

    EMAIL_DOMAIN     = "loadtest.invalid".freeze
    MEMBERS_PER_TEAM = 3

    # Shared by game_name (which writes it) and status (which reads the cohort
    # id back off it). A literal in two places is one edit away from silently
    # breaking status.
    GAME_NAME_PREFIX = "НЕ ИГРА — нагрузочный тест ".freeze

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
          :users     => users.count }
      end
    end

    attr_reader :cohort_id

    def initialize(source_game:, teams:, cohort_id:, base_url: nil)
      @source_game = source_game
      @teams       = Integer(teams.to_s, 10)
      @cohort_id   = cohort_id
      @base_url    = base_url || ENV.fetch("LOAD_TEST_BASE_URL", "http://localhost:3000")
    end

    def seed!
      raise CohortPresent, "cohort #{existing_cohort} still present" if existing_cohort

      ActiveRecord::Base.transaction do
        author = create_account("author")
        game   = GameCloner.new(@source_game).call(:name => game_name, :author => author)
        run    = open_run(game)
        teams  = Array.new(@teams) { |i| build_team(game, run, i) }

        manifest(game, run, teams)
      end
    end

    private

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

    def create_account(label)
      nickname = "#{prefix}#{label}-#{SecureRandom.hex(4)}"
      User.create!(:nickname              => nickname,
                   :email                 => "#{nickname}@#{EMAIL_DOMAIN}",
                   :password              => password,
                   :password_confirmation => password)
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

      GamePassing.create!(:game_id                  => game.id,
                          :team_id                  => team.id,
                          :game_run_id              => run.id,
                          :current_level_id         => level_for(game, index).id,
                          :current_level_entered_at => Time.now)

      { :email => captain.email, :password => password, :team_id => team.id }
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
