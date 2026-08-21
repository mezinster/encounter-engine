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
end
