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

  it "carries a hidden _method=delete, which is the only thing making the button work" do
    # This app has NO Turbo and NO rails-ujs. Nothing turns a button into a
    # DELETE for us: the form POSTs, and Rack::MethodOverride reads this hidden
    # field. Change `method: :delete` to `method: :post` in the partial and
    # every request spec, view spec and scenario on this branch stayed green
    # (28 specs, 3 scenarios) while a real author clicking Delete got a routing
    # error -- there is no POST route for a member path. Hence pinning the
    # value, not merely the presence of the field.
    render :partial => "game_files/file_table",
           :locals => { :files => [ @file ], :mode => :manage, :field_name => nil }

    form = Nokogiri::HTML(rendered).at_css("form")
    expect(form).to be_present
    expect(form.at_css("input[name='_method']")&.attr("value")).to eq("delete")
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
