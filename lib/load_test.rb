# The guard is a separate, injectable check rather than a `Rails.env.production?`
# call inside the seeder, so it can be tested without pretending to be in
# production -- and so the console screen (task 5) enforces the same rule as the
# rake task rather than a lookalike.
module LoadTest
  class Refused < StandardError; end

  # Two independent triggers, because neither alone is sufficient. The
  # environment NAME misses `DATABASE_URL=<prod> bin/rails ...`, which
  # replaces the connection while Rails.env stays "development" -- verified
  # directly, this is not theoretical. The ADAPTER misses the documented
  # production-boot probe in CLAUDE.md, which runs RAILS_ENV=production
  # against a scratch sqlite file. Production is the only postgresql
  # environment in config/database.yml (development/test are sqlite3), so
  # any postgres connection is treated as live regardless of what the
  # environment is called. This does NOT make a missed adapter safe: a
  # database this check fails to recognise as postgres makes `live?` false,
  # so `guard!` never fires and the write proceeds with no confirmation at
  # all -- the `start_with?("postgres")` half is a belt, not a fail-safe.
  # What actually makes this a non-issue today is that production really is
  # `postgresql` and `RAILS_ENV=production` trips the OTHER, independent
  # check regardless. A postgres staging database that isn't named
  # "production" is refused too, which is a pleasant side effect, not the
  # reason this is safe.
  def self.live?(environment: Rails.env, db_config: ActiveRecord::Base.connection_db_config)
    environment.to_s == "production" || db_config.adapter.to_s.start_with?("postgres")
  end

  # `confirmation:` defaults to the env var so every existing rake call site
  # (`LoadTest.guard!(cohort_id)`) keeps working unchanged. The console has no
  # env var to set from a browser -- it passes the operator's typed
  # `confirm_cohort_id` explicitly instead, which is its own per-operation
  # confirmation, performed by an authenticated superadmin, the same shape
  # `LOAD_TEST_CONFIRM` exists to provide for rake's non-interactive door.
  def self.guard!(cohort_id, confirmation: ENV["LOAD_TEST_CONFIRM"],
                  environment: Rails.env,
                  db_config: ActiveRecord::Base.connection_db_config)
    return unless live?(:environment => environment, :db_config => db_config)

    # A blank id can never be confirmed, and this is checked BEFORE the
    # comparison rather than after. `confirmation` is nil when the env var is
    # unset and the rake argument is nil when omitted, so `nil == nil` would
    # read as "confirmed" and authorise a nil-scoped sweep -- which matches
    # the entire cohort by e-mail domain -- against production with no
    # confirmation at all. An empty string pairs the same way.
    if cohort_id.to_s.empty?
      raise Refused, "a blank cohort id cannot be confirmed against production"
    end

    return if confirmation == cohort_id

    raise Refused, "set LOAD_TEST_CONFIRM=#{cohort_id} to confirm this against production"
  end

  # The rake seed task's only source of a base_url -- there is no request to
  # read one from (contrast Admin::LoadTestsController#seed, which has a real
  # request and uses `request.base_url` directly, never this method; see the
  # comment there for why the two doors deliberately stay different). A
  # cohort seeded here with no LOAD_TEST_BASE_URL used to fall back straight
  # to "http://localhost:3000", which produced a healthy-looking manifest
  # (cohort id, 120 teams) that pointed nowhere: the failure only surfaced
  # twenty minutes later, on a different machine, as a k6 "connection
  # refused" buried in a log. APP_HOST is already set in the production
  # container for mailer URLs (config/deploy.yml, config/environments/
  # production.rb), so it is derivable with nothing new to remember.
  #
  # Precedence: an operator who sets LOAD_TEST_BASE_URL explicitly means it,
  # and wins outright over everything else; otherwise APP_HOST; otherwise
  # localhost, for a bare development checkout that has neither.
  #
  # Refuses instead of guessing when it matters: seeding is cheap to redo in
  # seconds, so a wrong guess should be caught before it wastes anyone's
  # time, not discovered mid-run against production. `live?` is the same
  # two-signal check `guard!` uses (environment name OR postgres adapter), so
  # this refuses in exactly the situations `guard!` already treats as live.
  def self.resolve_base_url(env: ENV)
    url = if env["LOAD_TEST_BASE_URL"].present?
            env["LOAD_TEST_BASE_URL"]
          elsif env["APP_HOST"].present?
            "https://#{env["APP_HOST"]}"
          else
            "http://localhost:3000"
          end

    if live? && url.match?(%r{\Ahttps?://(localhost|127\.0\.0\.1)(:|/|\z)})
      raise Refused,
            "base_url resolved to #{url.inspect} while LoadTest.live? is true -- " \
            "set LOAD_TEST_BASE_URL (or APP_HOST, which it derives from) to a real host"
    end

    url
  end
end
