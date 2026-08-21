require "rails_helper"

describe "LoadTest.guard!" do
  around do |example|
    original = ENV["LOAD_TEST_CONFIRM"]
    example.run
    ENV["LOAD_TEST_CONFIRM"] = original
  end

  it "allows anything outside production" do
    ENV.delete("LOAD_TEST_CONFIRM")

    expect { LoadTest.guard!("lt-a", :environment => "development") }.not_to raise_error
  end

  it "refuses in production without confirmation" do
    ENV.delete("LOAD_TEST_CONFIRM")

    expect { LoadTest.guard!("lt-a", :environment => "production") }
      .to raise_error(LoadTest::Refused)
  end

  it "refuses in production when the confirmation names a different cohort" do
    ENV["LOAD_TEST_CONFIRM"] = "lt-b"

    expect { LoadTest.guard!("lt-a", :environment => "production") }
      .to raise_error(LoadTest::Refused)
  end

  it "allows production when the confirmation matches exactly" do
    ENV["LOAD_TEST_CONFIRM"] = "lt-a"

    expect { LoadTest.guard!("lt-a", :environment => "production") }.not_to raise_error
  end

  it "refuses a nil cohort id in production even when nothing is confirmed" do
    ENV.delete("LOAD_TEST_CONFIRM")

    expect { LoadTest.guard!(nil, :environment => "production") }
      .to raise_error(LoadTest::Refused)
  end

  it "refuses an empty cohort id that matches an empty confirmation" do
    ENV["LOAD_TEST_CONFIRM"] = ""

    expect { LoadTest.guard!("", :environment => "production") }
      .to raise_error(LoadTest::Refused)
  end

  # DATABASE_URL overrides the live connection without touching Rails.env --
  # verified directly: RAILS_ENV stays "development" while the adapter and
  # database both change. So the environment NAME alone is not sufficient;
  # the connection's own adapter is the second, independent signal, and
  # production is the only postgresql environment in config/database.yml.
  it "refuses a postgres connection even when the environment name says development" do
    ENV.delete("LOAD_TEST_CONFIRM")
    db_config = double(:adapter => "postgresql")

    expect {
      LoadTest.guard!("lt-a", :environment => "development", :db_config => db_config)
    }.to raise_error(LoadTest::Refused)
  end

  it "still refuses production when the connection itself is sqlite" do
    ENV.delete("LOAD_TEST_CONFIRM")
    db_config = double(:adapter => "sqlite3")

    expect {
      LoadTest.guard!("lt-a", :environment => "production", :db_config => db_config)
    }.to raise_error(LoadTest::Refused)
  end

  it "allows a sqlite connection outside production" do
    ENV.delete("LOAD_TEST_CONFIRM")
    db_config = double(:adapter => "sqlite3")

    expect {
      LoadTest.guard!("lt-a", :environment => "development", :db_config => db_config)
    }.not_to raise_error
  end

  # Every example above passes :environment explicitly. Mutate the keyword
  # default (environment: Rails.env) to a literal "development" and every one
  # of those examples stays green -- the rake tasks call guard! with a single
  # argument, exactly the call shape this example pins.
  it "reads Rails.env when no environment is given, the way the rake tasks call it" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    ENV.delete("LOAD_TEST_CONFIRM")

    expect { LoadTest.guard!("lt-a") }.to raise_error(LoadTest::Refused)
  end

  # The db_config: default carries the Critical fix (DATABASE_URL overriding
  # the connection while Rails.env stays unchanged). Every example above that
  # exercises a postgres connection injects a db_config double explicitly, so
  # none of them would notice the default itself silently reverting to
  # something that never checks the live connection. This is that check, the
  # same shape as the Rails.env example above but for the other keyword.
  it "reads the live connection when no db_config is given, the way the rake tasks call it" do
    ENV.delete("LOAD_TEST_CONFIRM")
    allow(ActiveRecord::Base).to receive(:connection_db_config)
      .and_return(double(:adapter => "postgresql"))

    expect { LoadTest.guard!("lt-a", :environment => "development") }
      .to raise_error(LoadTest::Refused)
  end
end
