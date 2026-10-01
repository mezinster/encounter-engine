# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "index/index", type: :view do
  it "renders the home page with a link to the games list" do
    # No games exist here, so this is the empty state.
    assign(:upcoming, UpcomingGames.call)
    # logged_in? and current_user are controller helpers, not available in
    # view specs; the guest/signed-in branches and helpers call them.
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }

    render

    # Literal Russian: an include(I18n.t(key)) assertion cannot fail on a missing key.
    expect(rendered).to include("Сейчас игр не запланировано")
    expect(rendered).to include("Список игр")
    expect(rendered).to include(games_path)
  end
end
