require "rails_helper"
require "rake"

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
end
