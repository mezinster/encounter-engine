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
end
