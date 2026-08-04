# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "index/index", type: :view do
  it "renders the home page with a link to the games list" do
    render

    expect(rendered).to include(I18n.t("index.index.title"))
    expect(rendered).to include(I18n.t("index.index.games_list"))
    expect(rendered).to include(games_path)
  end
end
