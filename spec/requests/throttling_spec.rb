require "rails_helper"

describe "the cache backing request throttling", type: :request do
  it "counts with increment and expires the key" do
    key = "throttle:spec:1.2.3.4:0"

    expect(Rails.cache.increment(key, 1, :expires_in => 60.seconds)).to eq(1)
    expect(Rails.cache.increment(key, 1, :expires_in => 60.seconds)).to eq(2)
    expect(Rails.cache.read(key)).to eq(2)
  end

  # Without this the first throttle spec to run leaves a counter behind and the
  # second one starts mid-window -- a failure that only appears when the suite
  # is run in a different order.
  it "starts every example with an empty cache" do
    expect(Rails.cache.read("throttle:spec:1.2.3.4:0")).to be_nil
  end
end
