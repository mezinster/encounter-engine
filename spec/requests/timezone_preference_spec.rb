require "rails_helper"

describe "choosing a timezone in the profile", type: :request do
  let(:user) { create_user }

  before { put login_path, :params => { :email => user.email, :password => "1234" } }

  # NOTE: time_zone_select emits Rails' FRIENDLY zone names -- the option value
  # is "Berlin", not "Europe/Berlin", and the label is "(GMT+01:00) Berlin".
  # ActiveSupport::TimeZone[] resolves both forms, so the concern works either
  # way, but these examples must use what the form actually submits.
  it "offers the control on the profile form" do
    get edit_user_path(user)

    expect(response.body).to include(I18n.t("users.edit.timezone_label"))
    expect(response.body).to include(%{value="Berlin"})
    # include_blank is the only route back to NULL -- without it, the <select>
    # has no empty option and a user who has picked a zone can never return
    # to "use the instance default" through this form again.
    expect(response.body).to match(%r{<option value="">})
  end

  it "saves the choice" do
    patch user_path(user), :params => { :user => { :nickname => user.nickname, :timezone => "Berlin" } }

    expect(user.reload.timezone).to eq("Berlin")
  end

  # include_blank is what makes the setting reversible. Without it NULL stops
  # being reachable through the UI the moment anyone picks a zone, and
  # "instance default" becomes a state you can leave but never return to.
  it "can be cleared back to the instance default" do
    user.update!(:timezone => "Berlin")

    patch user_path(user), :params => { :user => { :nickname => user.nickname, :timezone => "" } }

    expect(user.reload.timezone).to be_blank
  end

  it "shows the chosen zone on the profile page" do
    user.update!(:timezone => "Berlin")

    get users_path

    expect(response.body).to include(I18n.t("users.index.timezone_label"))
    expect(response.body).to include("Berlin")
  end

  it "shows the instance default on the profile page when none is chosen" do
    get users_path

    expect(response.body).to include(I18n.t("users.edit.timezone_default"))
  end

  # Only reachable via a raw PATCH (the form never offers an unrecognised
  # value), but TimeZoneSelection already falls back to the instance default
  # for a value it can't resolve -- the page must say so too, not print the
  # raw stored string as though it were an active choice.
  it "shows the instance default on the profile page for an unrecognised stored zone" do
    user.update_column(:timezone, "Not_A_Real_Zone")

    get users_path

    expect(response.body).to include(I18n.t("users.edit.timezone_default"))
    expect(response.body).not_to include("Not_A_Real_Zone")
  end
end
