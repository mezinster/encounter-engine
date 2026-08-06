require "rails_helper"

describe "the viewer's timezone", type: :request do
  let(:user) { create_user }
  let(:game) { create_game(:author => user, :is_draft => false) }

  # An absolute instant, so the assertions below are about rendering and not
  # about how the fixture's string was parsed. 2099-01-01 12:00 UTC is 13:00 in
  # Berlin (CET, +1 in January) and 16:00 in Tbilisi (+4).
  before { game.update_column(:starts_at, Time.utc(2099, 1, 1, 12, 0, 0)) }

  def sign_in(u)
    put login_path, :params => { :email => u.email, :password => "1234" }
  end

  it "renders a time in the user's chosen zone" do
    user.update!(:timezone => "Berlin")
    sign_in(user)

    get game_path(game)

    expect(response.body).to include("2099-01-01 13:00")
  end

  it "renders a different user's chosen zone differently for the same instant" do
    user.update!(:timezone => "Tbilisi")
    sign_in(user)

    get game_path(game)

    expect(response.body).to include("2099-01-01 16:00")
  end

  # THE compatibility contract. Four frozen features assert exact wall-clock
  # strings and their users never set a timezone; if this example breaks, those
  # features are about to break too.
  it "falls back to the instance default when the user has not chosen one" do
    expect(user.timezone).to be_nil
    sign_in(user)

    get game_path(game)

    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(Time.zone), :format => :short))
  end

  # A stored zone can go stale when the tzdata Rails ships changes. A profile
  # column must never be able to 500 every page the user visits.
  it "falls back rather than raising on a zone name Rails does not know" do
    user.update_column(:timezone, "Middle/Earth")
    sign_in(user)

    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(Time.zone), :format => :short))
  end

  it "applies the instance default to a signed-out visitor" do
    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(Time.zone), :format => :short))
  end

  # This is what around_action buys over before_action, and it is invisible to
  # every other example here: a before_action version would leak the last
  # request's zone into whatever runs next on the same thread, and all the
  # examples above would still pass.
  it "does not leak the zone past the request" do
    instance_default = Time.zone.name
    user.update!(:timezone => "Tbilisi")
    sign_in(user)

    get game_path(game)

    expect(Time.zone.name).to eq(instance_default)
  end
end
