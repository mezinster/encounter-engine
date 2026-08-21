# A thin shell. The logic lives in lib/load_test/ so it is testable without
# invoking rake, and so the console screen drives exactly the same code.
namespace :load_test do
  desc "Seed a load-test cohort from a source game: rake load_test:seed[42,120]"
  task :seed, [ :source_game_id, :teams ] => :environment do |_t, args|
    # A random cohort id can never be confirmed in advance: if LOAD_TEST_COHORT
    # is unset, `guard!` below would refuse with a printed id that changes on
    # every retry, since it's re-generated each run -- an instruction the
    # operator can never actually follow. Refuse BEFORE generating one instead,
    # so the fix is "set both variables to the same value", not "read the
    # error and try again forever".
    if LoadTest.live? && ENV["LOAD_TEST_COHORT"].to_s.empty?
      raise LoadTest::Refused,
            "set LOAD_TEST_COHORT=<id> and LOAD_TEST_CONFIRM=<the same id> " \
            "to run this against production -- a generated id can't be confirmed in advance"
    end

    cohort_id = ENV.fetch("LOAD_TEST_COHORT") { "lt-#{Date.today}-#{SecureRandom.hex(2)}" }
    LoadTest.guard!(cohort_id)

    manifest = LoadTest::Seeder.new(
      :source_game => Game.find(args.fetch(:source_game_id)),
      :teams       => args.fetch(:teams),
      :cohort_id   => cohort_id,
      :base_url    => ENV["LOAD_TEST_BASE_URL"]
    ).seed!

    # seed! already committed above -- the cohort is live in the database by
    # this point, regardless of what happens next. If the manifest write fails
    # (Errno::EEXIST from ManifestFile.write!'s O_EXCL, most likely a stale
    # file at a predictable /tmp path), the operator must not be left with a
    # live, unrecorded cohort and no way to find it: print the id and the
    # exact teardown command FIRST, before anything can raise, then explain
    # what didn't happen and re-raise so the failure still surfaces.
    puts "cohort:   #{cohort_id}"
    puts
    puts "TEARDOWN IS MANDATORY. When the run is over:"
    puts "  LOAD_TEST_CONFIRM=#{cohort_id} bin/rails 'load_test:teardown[#{cohort_id}]'"

    begin
      path = LoadTest::ManifestFile.write!(
        manifest, :path => ENV.fetch("LOAD_TEST_MANIFEST", "/tmp/#{cohort_id}.json")
      )
      puts
      puts "manifest: #{path}  (contains live credentials -- never commit it)"
    rescue Errno::EEXIST => e
      warn ""
      warn "manifest NOT written: #{e.message}"
      warn "the cohort above is live regardless -- the teardown command still applies"
      raise
    end
  end

  # teardown! validates the id against the cohort actually present and refuses
  # on a mismatch, so a stale id cannot destroy a live cohort -- the guard below
  # only compares two copies of what the operator typed, and cannot catch that
  # on its own.
  #
  # A cohort whose game was already removed by hand cannot be named by
  # `status`, so this task cannot confirm it either -- LoadTest.guard! refuses
  # a blank cohort id in production outright, on purpose (a blank id can never
  # be confirmed, so it must never be treated as authorised). Sweeping those
  # leftovers is a deliberate out-of-band action, not a rake flag:
  #   bin/rails runner 'puts LoadTest::Seeder.teardown!(nil)'
  # which bypasses the guard because the operator chose to step outside it.
  # This belongs in an operator runbook, not behind a rake flag.
  desc "Remove a load-test cohort: rake load_test:teardown[lt-2026-08-21-ab]"
  task :teardown, [ :cohort_id ] => :environment do |_t, args|
    cohort_id = args[:cohort_id]
    LoadTest.guard!(cohort_id)
    begin
      puts "removed #{LoadTest::Seeder.teardown!(cohort_id)} rows"
    rescue ArgumentError => e
      warn e.message
      warn "Check `load_test:status` to see what cohort id (if any) is actually present."
      raise
    end
    puts "status: #{LoadTest::Seeder.status.inspect}"
  end

  desc "Report whether a load-test cohort is present"
  task :status => :environment do
    puts LoadTest::Seeder.status.inspect
  end
end
