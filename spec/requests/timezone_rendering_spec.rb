require "rails_helper"

describe "timestamps that carry their zone", type: :request do
  let(:user) { create_user }
  let(:game) { create_game(:author => user, :is_draft => false) }

  before do
    set_game_schedule!(game, :starts_at => Time.utc(2099, 1, 1, 12, 0, 0),
                             :registration_deadline => Time.utc(2098, 12, 1, 10, 0, 0))
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

describe "the results screen's zone statement", type: :request do
  let(:user) { create_user }

  before do
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Regression example for the bug where the statement was built from
  # Time.zone.formatted_offset -- the zone's STANDARD-time offset, which
  # knows nothing about DST -- while the times in the table below it are
  # rendered from real instants, which do observe DST. Picking a date inside
  # a DST period is what makes this example able to fail: Berlin's base
  # offset is +01:00 (CET) but 2024-08-06 falls in +02:00 (CEST), so a
  # zone-derived (rather than instant-derived) offset renders the wrong
  # label right alongside times that disagree with it.
  it "states the offset actually in effect for the game, not the zone's standard-time offset" do
    user.update!(:timezone => "Berlin")
    game = create_game(:is_draft => false)
    # game_starts_in_the_future only validates on create -- update_column
    # bypasses validations entirely, same pattern the spec above this one
    # uses to move a game's start into the past.
    set_game_schedule!(game, :starts_at => Time.utc(2024, 8, 6, 9, 0, 0))
    level = create_level(:game => game)
    create_game_passing(:level => level, :finished_at => Time.utc(2024, 8, 6, 11, 30, 0))

    get game_passings_show_results_path(:game_id => game.id)

    # 11:30 UTC on 2024-08-06 is 13:30 in Berlin under CEST (+02:00).
    expect(response.body).to include("13:30:00")
    expect(response.body).to include(I18n.t("game_passings.show_results.times_in_zone", :zone => "+02:00"))
    expect(response.body).not_to include(I18n.t("game_passings.show_results.times_in_zone", :zone => "+01:00"))
  end
end

describe "the game-form start-time round trip", type: :request do
  # Design spec §7 ("an author in a non-instance zone enters a start time on
  # the game form and the stored UTC instant is the one their local time
  # denotes") was verified by driving the app but never had an automated
  # example. This is that example: a bare, offset-less string submitted by a
  # Tokyo author must be parsed AS Tokyo time (via the TimeZoneSelection
  # around_action, not the instance default) and stored as the equivalent
  # UTC instant.
  it "stores the UTC instant the author's local time denotes, not the instance default's" do
    author = create_user
    author.update!(:timezone => "Tokyo")
    put login_path, :params => { :email => author.email, :password => "1234" }

    post games_path, :params => {
      :game => {
        :name => "Round-trip game #{rand(1_000_000)}",
        :description => "Round-trip test",
        :max_team_number => 10,
        :starts_at => "2099-07-01 18:00",
      },
    }

    expect(Game.last.starts_at).to eq(Time.utc(2099, 7, 1, 9, 0, 0))

    get game_path(Game.last)
    expect(response.body).to include("2099-07-01 18:00 (+09:00)")
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
