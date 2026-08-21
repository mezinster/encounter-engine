require "rails_helper"
require "rake"
require "tmpdir"

describe "load_test rake tasks" do
  before(:all) do
    Rake.application.rake_require("tasks/load_test", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  before(:each) do
    Rake::Task.tasks.each(&:reenable)
  end

  # Reordering "guard first, then mutate" would not be caught by an
  # outcome-based example -- both orders produce the same visible effect when
  # the guard happens not to fire, and in this test environment (sqlite,
  # RAILS_ENV=test) it never fires. Pinned here instead: with the guard
  # stubbed to always refuse, the destructive call must never even be
  # attempted, regardless of environment.
  describe "load_test:seed" do
    it "never builds a seeder if the guard refuses" do
      allow(LoadTest).to receive(:guard!).and_raise(LoadTest::Refused, "nope")
      expect(LoadTest::Seeder).not_to receive(:new)

      expect { Rake::Task["load_test:seed"].invoke("1", "1") }
        .to raise_error(LoadTest::Refused)
    end
  end

  describe "load_test:teardown" do
    it "never calls Seeder.teardown! if the guard refuses" do
      allow(LoadTest).to receive(:guard!).and_raise(LoadTest::Refused, "nope")
      expect(LoadTest::Seeder).not_to receive(:teardown!)

      expect { Rake::Task["load_test:teardown"].invoke("lt-a") }
        .to raise_error(LoadTest::Refused)
    end

    # The manifest's `codes` are the SOURCE game's real answer codes, copied
    # verbatim by GameCloner -- it stays meaningful long after the seeded
    # accounts are gone. Before this fix only the console's teardown removed
    # it; rake's left it sitting at a predictable path forever. Same path
    # `load_test:seed` wrote (LOAD_TEST_MANIFEST, else the default), which is
    # exactly the file the operator was told to keep -- see docs/runbooks.
    it "deletes the manifest file the seed task wrote" do
      game = create_game
      create_level(:game => game, :name => "L1", :correct_answer => "aaa")

      Dir.mktmpdir("load-test-teardown-manifest-spec") do |dir|
        manifest_path = File.join(dir, "manifest.json")
        original_manifest = ENV["LOAD_TEST_MANIFEST"]
        original_cohort   = ENV["LOAD_TEST_COHORT"]
        ENV["LOAD_TEST_MANIFEST"] = manifest_path
        ENV["LOAD_TEST_COHORT"]   = "lt-teardown-spec"

        begin
          Rake::Task["load_test:seed"].invoke(game.id.to_s, "1")
          expect(File.exist?(manifest_path)).to be true

          Rake::Task["load_test:teardown"].invoke("lt-teardown-spec")

          expect(File.exist?(manifest_path)).to be false
        ensure
          ENV["LOAD_TEST_MANIFEST"] = original_manifest
          ENV["LOAD_TEST_COHORT"]   = original_cohort
          File.delete(manifest_path) if File.exist?(manifest_path)
        end
      end
    end

    # Best-effort, mirroring the identical fix in
    # Admin::LoadTestsController#teardown: a teardown that already removed
    # every row in the database must not fail just because the manifest file
    # is already gone (or, in production, some other SystemCallError).
    it "does not raise when the manifest file is already gone" do
      game = create_game
      create_level(:game => game, :name => "L1", :correct_answer => "aaa")

      Dir.mktmpdir("load-test-teardown-manifest-spec") do |dir|
        manifest_path = File.join(dir, "manifest.json")
        original_manifest = ENV["LOAD_TEST_MANIFEST"]
        original_cohort   = ENV["LOAD_TEST_COHORT"]
        ENV["LOAD_TEST_MANIFEST"] = manifest_path
        ENV["LOAD_TEST_COHORT"]   = "lt-teardown-spec2"

        begin
          Rake::Task["load_test:seed"].invoke(game.id.to_s, "1")
          File.delete(manifest_path)

          expect { Rake::Task["load_test:teardown"].invoke("lt-teardown-spec2") }
            .not_to raise_error
        ensure
          ENV["LOAD_TEST_MANIFEST"] = original_manifest
          ENV["LOAD_TEST_COHORT"]   = original_cohort
        end
      end
    end
  end

  describe "load_test:seed, in production" do
    it "refuses before generating a cohort id when LOAD_TEST_COHORT is unset" do
      allow(LoadTest).to receive(:live?).and_return(true)
      original = ENV["LOAD_TEST_COHORT"]
      ENV.delete("LOAD_TEST_COHORT")
      expect(LoadTest::Seeder).not_to receive(:new)

      expect { Rake::Task["load_test:seed"].invoke("1", "1") }
        .to raise_error(LoadTest::Refused, /LOAD_TEST_COHORT/)
    ensure
      ENV["LOAD_TEST_COHORT"] = original
    end
  end

  # The whole point of resolving base_url in the rake task itself (rather
  # than leaving it to Seeder's own default) is so the operator sees it
  # printed -- a manifest that silently pointed at localhost is exactly what
  # produced the incident this fixes (see LoadTest.resolve_base_url).
  describe "load_test:seed prints the resolved base_url" do
    it "prints base_url beside the cohort id, derived from APP_HOST when LOAD_TEST_BASE_URL is unset" do
      game = create_game
      create_level(:game => game, :name => "L1", :correct_answer => "aaa")

      Dir.mktmpdir("load-test-base-url-spec") do |dir|
        manifest_path      = File.join(dir, "manifest.json")
        original_manifest  = ENV["LOAD_TEST_MANIFEST"]
        original_cohort    = ENV["LOAD_TEST_COHORT"]
        original_base_url  = ENV["LOAD_TEST_BASE_URL"]
        original_app_host  = ENV["APP_HOST"]
        ENV["LOAD_TEST_MANIFEST"]  = manifest_path
        ENV["LOAD_TEST_COHORT"]    = "lt-base-url-spec"
        ENV.delete("LOAD_TEST_BASE_URL")
        ENV["APP_HOST"] = "game.mezin.eu"

        output = StringIO.new
        original_stdout = $stdout
        $stdout = output

        begin
          Rake::Task["load_test:seed"].invoke(game.id.to_s, "1")
        ensure
          $stdout = original_stdout
          ENV["LOAD_TEST_MANIFEST"] = original_manifest
          ENV["LOAD_TEST_COHORT"]   = original_cohort
          ENV["LOAD_TEST_BASE_URL"] = original_base_url
          ENV["APP_HOST"]           = original_app_host
        end

        expect(output.string).to include("base_url: https://game.mezin.eu")
        expect(JSON.parse(File.read(manifest_path))["base_url"]).to eq("https://game.mezin.eu")
      end
    end
  end

  # seed! commits before the manifest is ever written, so a write failure
  # (here: O_EXCL finding a pre-existing file, the realistic case -- a stale
  # manifest at a predictable path) must not strand the operator with a live,
  # unrecorded cohort. The cohort id and teardown command have to appear on
  # stdout BEFORE the raise, not just somewhere in a rescue block that could
  # be reordered or dropped.
  describe "load_test:seed, when the manifest write fails" do
    it "prints the cohort id and teardown command before raising, and does not swallow the failure" do
      game = create_game
      create_level(:game => game, :name => "L1", :correct_answer => "aaa")

      Dir.mktmpdir("load-test-eexist-spec") do |dir|
        manifest_path = File.join(dir, "manifest.json")
        File.write(manifest_path, "pre-existing content from an earlier run")

        original_manifest = ENV["LOAD_TEST_MANIFEST"]
        original_cohort   = ENV["LOAD_TEST_COHORT"]
        ENV["LOAD_TEST_MANIFEST"] = manifest_path
        ENV["LOAD_TEST_COHORT"]   = "lt-eexist-spec"

        output = StringIO.new
        original_stdout = $stdout
        $stdout = output

        begin
          expect { Rake::Task["load_test:seed"].invoke(game.id.to_s, "1") }
            .to raise_error(Errno::EEXIST)
        ensure
          $stdout = original_stdout
          ENV["LOAD_TEST_MANIFEST"] = original_manifest
          ENV["LOAD_TEST_COHORT"]   = original_cohort
        end

        printed = output.string
        cohort_line   = printed.index("cohort:   lt-eexist-spec")
        teardown_line = printed.index(
          "LOAD_TEST_CONFIRM=lt-eexist-spec bin/rails 'load_test:teardown[lt-eexist-spec]'"
        )

        expect(cohort_line).not_to be_nil
        expect(teardown_line).not_to be_nil
        expect(printed).not_to include("manifest.json  (contains live credentials")

        # The failure is not swallowed by whatever prints the cohort id --
        # the cohort really was seeded, matching what the printed teardown
        # command promises.
        expect(LoadTest::Seeder.status[:cohort_id]).to eq("lt-eexist-spec")
      end
    end
  end
end
