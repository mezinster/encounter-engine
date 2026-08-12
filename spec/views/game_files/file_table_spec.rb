require "rails_helper"

describe "game_files/_file_table", :type => :view do
  before(:each) do
    @game = create_game
    @file = create_game_file(:game => @game, :filename => "дом.jpg")
  end

  it "renders an action button in manage mode" do
    render :partial => "game_files/file_table",
           :locals => { :files => [ @file ], :mode => :manage, :field_name => nil }

    expect(rendered).to include("дом.jpg")
    expect(rendered).to include(I18n.t("game_files.index.delete"))
  end

  it "renders a checkbox in picker mode, named for the form field" do
    # Phase 3 renders this mode inside the level form. It must be a real
    # checkbox so rack-test can check/uncheck it without a browser driver.
    render :partial => "game_files/file_table",
           :locals => { :files => [ @file ], :mode => :picker,
                        :field_name => "level[game_file_ids]" }

    expect(rendered).to include("level[game_file_ids][]")
    expect(rendered).to include(%(value="#{@file.id}"))
    expect(rendered).not_to include(I18n.t("game_files.index.delete"))
  end
end
