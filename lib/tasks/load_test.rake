# A thin shell. The logic lives in lib/load_test/ so it is testable without
# invoking rake, and so the console screen drives exactly the same code.
namespace :load_test do
  desc "Seed a load-test cohort from a source game: rake load_test:seed[42,120]"
  task :seed, [ :source_game_id, :teams ] => :environment do |_t, args|
    cohort_id = ENV.fetch("LOAD_TEST_COHORT") { "lt-#{Date.today}-#{SecureRandom.hex(2)}" }
    LoadTest.guard!(cohort_id)

    manifest = LoadTest::Seeder.new(
      :source_game => Game.find(args.fetch(:source_game_id)),
      :teams       => args.fetch(:teams),
      :cohort_id   => cohort_id,
      :base_url    => ENV["LOAD_TEST_BASE_URL"]
    ).seed!

    path = ENV.fetch("LOAD_TEST_MANIFEST", "/tmp/#{cohort_id}.json")
    File.write(path, JSON.pretty_generate(manifest))
    File.chmod(0600, path)

    puts "cohort:   #{cohort_id}"
    puts "manifest: #{path}  (contains live credentials -- never commit it)"
    puts
    puts "TEARDOWN IS MANDATORY. When the run is over:"
    puts "  LOAD_TEST_CONFIRM=#{cohort_id} bin/rails 'load_test:teardown[#{cohort_id}]'"
  end

  # teardown! validates the id against the cohort actually present and refuses
  # on a mismatch, so a stale id cannot destroy a live cohort -- the guard below
  # only compares two copies of what the operator typed, and cannot catch that
  # on its own. The one escape hatch: if the cohort's GAME is already gone but
  # its users are not, status reports no cohort id and only `teardown!(nil)`
  # sweeps them. That is a real state (a half-finished manual cleanup), so the
  # task documents it rather than leaving an operator to conclude the rows are
  # unreachable.
  desc "Remove a load-test cohort: rake load_test:teardown[lt-2026-08-21-ab]"
  task :teardown, [ :cohort_id ] => :environment do |_t, args|
    cohort_id = args.fetch(:cohort_id)
    LoadTest.guard!(cohort_id)
    begin
      puts "removed #{LoadTest::Seeder.teardown!(cohort_id)} rows"
    rescue ArgumentError => e
      warn e.message
      warn "If the cohort's game was already removed by hand, status cannot name"
      warn "the cohort and only `load_test:teardown[]` (empty id) will sweep the"
      warn "leftover accounts. Check `load_test:status` first."
      raise
    end
    puts "status: #{LoadTest::Seeder.status.inspect}"
  end

  desc "Report whether a load-test cohort is present"
  task :status => :environment do
    puts LoadTest::Seeder.status.inspect
  end
end
