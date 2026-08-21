require "rails_helper"

# The rake seed task's only source of a base_url -- see LoadTest.resolve_base_url's
# own comment for the incident this fixes: a production seed with no
# LOAD_TEST_BASE_URL fell back straight to "http://localhost:3000", producing a
# healthy-looking manifest that pointed nowhere.
describe "LoadTest.resolve_base_url" do
  it "prefers an explicit LOAD_TEST_BASE_URL over everything else" do
    env = { "LOAD_TEST_BASE_URL" => "https://explicit.example",
            "APP_HOST"           => "app-host.example" }

    expect(LoadTest.resolve_base_url(:env => env)).to eq("https://explicit.example")
  end

  it "derives https://APP_HOST when LOAD_TEST_BASE_URL is unset" do
    env = { "APP_HOST" => "game.mezin.eu" }

    expect(LoadTest.resolve_base_url(:env => env)).to eq("https://game.mezin.eu")
  end

  it "falls back to localhost when neither is set, outside a live environment" do
    expect(LoadTest.resolve_base_url(:env => {})).to eq("http://localhost:3000")
  end

  # Seeding is cheap to redo in seconds; a manifest that looks healthy but
  # points nowhere is only discovered twenty minutes later, on a different
  # machine, as a k6 "connection refused" buried in a log. Refuse up front
  # instead of guessing. Stubbing LoadTest.live? directly (rather than
  # injecting environment/db_config) matches how resolve_base_url actually
  # calls it -- with no arguments, same as the rake task's own top-of-file
  # `LoadTest.live?` check.
  it "raises when live and the resolved url would still be localhost" do
    allow(LoadTest).to receive(:live?).and_return(true)

    expect { LoadTest.resolve_base_url(:env => {}) }
      .to raise_error(LoadTest::Refused, /LOAD_TEST_BASE_URL/)
  end

  it "does not raise when live but LOAD_TEST_BASE_URL or APP_HOST resolves to a real host" do
    allow(LoadTest).to receive(:live?).and_return(true)

    expect(LoadTest.resolve_base_url(:env => { "APP_HOST" => "game.mezin.eu" }))
      .to eq("https://game.mezin.eu")
  end
end
