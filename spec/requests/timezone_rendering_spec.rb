require "rails_helper"

describe "timestamps that carry their zone", type: :request do
  let(:user) { create_user }
  let(:game) { create_game(:author => user, :is_draft => false) }

  before do
    game.update_column(:starts_at, Time.utc(2099, 1, 1, 12, 0, 0))
    game.update_column(:registration_deadline, Time.utc(2098, 12, 1, 10, 0, 0))
    user.update!(:timezone => "Berlin")
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "labels the game start with its offset" do
    get game_path(game)

    expect(response.body).to include("2099-01-01 13:00 (+01:00)")
  end

  it "labels the registration deadline with its offset" do
    get game_path(game)

    expect(response.body).to include("2098-12-01 11:00 (+01:00)")
  end

  # The countdown used to emit new Date(2099,0,1,13,0,0) -- bare numbers the
  # BROWSER reads in ITS own zone, so the countdown disagreed with the time
  # printed directly above it for anyone whose browser zone differed from the
  # server's. Milliseconds since the epoch is zone-free by construction.
  it "gives the countdown an absolute instant, not a local-time tuple" do
    get game_path(game)

    expect(response.body).to include("new Date(#{(game.starts_at + 1).to_i * 1000})")
    expect(response.body).not_to match(/new Date\(\d{4},\d+,\d+,/)
  end
end

describe ApplicationHelper, "#l_with_zone", type: :helper do
  it "appends the offset of the current zone" do
    Time.use_zone("Berlin") do
      expect(helper.l_with_zone(Time.utc(2099, 1, 1, 12, 0, 0), :format => :short))
        .to eq("2099-01-01 13:00 (+01:00)")
    end
  end

  it "returns nil for a nil time, so callers can guard on presence" do
    expect(helper.l_with_zone(nil, :format => :short)).to be_nil
  end
end
