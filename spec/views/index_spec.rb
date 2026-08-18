# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "index/index", type: :view do
  it "renders the home page with a link to the games list" do
    assign(:games, [])
    # The games list partial's gated_play_status helper calls logged_in? and
    # current_user, which are controller helpers not available in view specs.
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }

    render

    expect(rendered).to include(I18n.t("index.index.title"))
    expect(rendered).to include(I18n.t("index.index.games_list"))
    expect(rendered).to include(games_path)
  end
end
