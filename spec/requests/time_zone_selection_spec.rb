require "rails_helper"

describe "the viewer's timezone", type: :request do
  let(:user) { create_user }
  let(:game) { create_game(:author => user, :is_draft => false) }

  # The instance default straight from configuration, not from `Time.zone` at
  # assertion time. `Time.zone` is mutable global state that this very spec
  # (and any other request spec sharing the process) can leave set to
  # something other than the default; deriving "what should render for a user
  # with no preference" from it would make the assertion trivially true
  # whatever a prior example leaked, defeating the point of the fallback
  # examples below. `Rails.application.config.time_zone` is fixed
  # configuration and immune to that.
  let(:instance_default_zone) { Rails.application.config.time_zone }

  # An absolute instant, so the assertions below are about rendering and not
  # about how the fixture's string was parsed. 2099-01-01 12:00 UTC is 13:00 in
  # Berlin (CET, +1 in January) and 16:00 in Tbilisi (+4).
  before { set_game_schedule!(game, :starts_at => Time.utc(2099, 1, 1, 12, 0, 0)) }

  # Belt and braces alongside around_action's own restore: whatever a test
  # leaves Time.zone as, the next file that runs must not inherit it.
  after { Time.zone = instance_default_zone }

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

    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(instance_default_zone), :format => :short))
  end

  # A stored zone can go stale when the tzdata Rails ships changes. A profile
  # column must never be able to 500 every page the user visits.
  it "falls back rather than raising on a zone name Rails does not know" do
    user.update_column(:timezone, "Middle/Earth")
    sign_in(user)

    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(instance_default_zone), :format => :short))
  end

  it "applies the instance default to a signed-out visitor" do
    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(instance_default_zone), :format => :short))
  end

  # This is what around_action buys over before_action, and it is invisible to
  # every other example here: a before_action version would leak the last
  # request's zone into whatever runs next on the same thread, and all the
  # examples above would still pass.
  #
  # The expected value here is the configured default, not `Time.zone.name`
  # captured just before the request: if a bug already leaked a prior
  # example's zone, capturing "before" from live state would capture the
  # leaked value too, and a before/after comparison would match even with the
  # bug present.
  it "does not leak the zone past the request" do
    user.update!(:timezone => "Tbilisi")
    sign_in(user)

    get game_path(game)

    expect(Time.zone.name).to eq(instance_default_zone)
  end
end
