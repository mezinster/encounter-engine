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

    attr_reader :cohort_id

    def initialize(source_game:, teams:, cohort_id:, base_url: nil)
      @source_game = source_game
      @teams       = Integer(teams)
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
      "НЕ ИГРА — нагрузочный тест #{@cohort_id}"
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
