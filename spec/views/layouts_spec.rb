# -*- encoding : utf-8 -*-
require "rails_helper"

# Controller specs (spec/controllers/) never render templates in this suite,
# so nothing exercises app/views/layouts/*.html.erb through the normal test
# run. These view specs actually compile and render the ERB, catching
# NameError/NoMethodError from stale Merb helper calls (partial/resource/url/
# catch_content) that a controller-spec-only gate would miss entirely.
#
# `current_user`/`logged_in?` are private methods on ApplicationController
# exposed via `helper_method`; a bare ActionView::TestCase view (no real
# controller instance behind it) doesn't have them, so `allow(view).to
# receive(...)` fails under `verify_partial_doubles` ("does not implement").
# `define_singleton_method` sidesteps that -- it's a real method definition,
# not a verified mock expectation.
RSpec.describe "layouts/application", type: :view do
  it "renders the guest chrome" do
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }

    render

    expect(rendered).to include(I18n.t("layout.title"))
    expect(rendered).to include(I18n.t("layout.header.home"))
    expect(rendered).to include(I18n.t("layout.left_menu.login_legend"))
    expect(rendered).to include(I18n.t("layout.left_menu.login"))
    expect(rendered).to include(I18n.t("layout.left_menu.signup"))
    expect(rendered).to include(login_path)
    expect(rendered).to include(signup_path)
  end

  it "renders the signed-in chrome, including a team membership" do
    captain = create_user
    team = create_team(captain: captain)
    captain.reload

    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { captain }

    render

    expect(rendered).to include(captain.nickname)
    expect(rendered).to include(team.name)
    expect(rendered).to include(I18n.t("layout.left_menu.dashboard"))
    expect(rendered).to include(I18n.t("layout.left_menu.profile"))
    expect(rendered).to include(I18n.t("layout.left_menu.team_room"))
    expect(rendered).to include(I18n.t("layout.left_menu.all_games"))
    expect(rendered).to include(I18n.t("layout.left_menu.logout"))
    expect(rendered).to include(dashboard_path)
    expect(rendered).to include(team_room_path)
  end

  it "renders the signed-in chrome for a user without a team" do
    user = create_user

    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:current_user) { user }

    render

    expect(rendered).to include(I18n.t("layout.left_menu.create_team"))
    expect(rendered).to include(new_team_path)
  end
end

RSpec.describe "layouts/in_game", type: :view do
  it "renders the guest chrome without the left menu column" do
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }

    render

    expect(rendered).to include(I18n.t("layout.title"))
    expect(rendered).to include(I18n.t("layout.header.home"))
    expect(rendered).not_to include('id="drawer"')
    expect(rendered).to include('page--focused')
  end
end
