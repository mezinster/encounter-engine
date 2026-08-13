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

  # Task 2 fix round (Minor): this file was never extended for the two
  # things Task 2 actually changed in this partial -- the thumbnail cell
  # (string "IMG"/"PDF" -> a real <img> at the thumb variant) and
  # checked_ids (hard-coded false -> the picker's real pre-checked state).
  describe "checked_ids (picker mode)" do
    it "checks a box whose file id is in checked_ids" do
      render :partial => "game_files/file_table",
             :locals => { :files => [ @file ], :mode => :picker,
                          :field_name => "level[game_file_ids]",
                          :checked_ids => [ @file.id ] }

      box = Nokogiri::HTML(rendered).at_css("#game_file_#{@file.id}")
      expect(box["checked"]).to be_present
    end

    it "leaves a box unchecked when its file id is not in checked_ids" do
      render :partial => "game_files/file_table",
             :locals => { :files => [ @file ], :mode => :picker,
                          :field_name => "level[game_file_ids]",
                          :checked_ids => [ @file.id + 1 ] }

      box = Nokogiri::HTML(rendered).at_css("#game_file_#{@file.id}")
      expect(box["checked"]).to be_nil
    end

    it "does not raise in :manage mode, which never passes checked_ids" do
      expect {
        render :partial => "game_files/file_table",
               :locals => { :files => [ @file ], :mode => :manage, :field_name => nil }
      }.not_to raise_error
    end
  end

  describe "the thumbnail cell" do
    it "renders a bounded <img> at the thumb variant for a file with an existing thumbnail" do
      photo = GameFileUpload.new(@game, fixture_upload("photo.jpg"), create_user).call

      render :partial => "game_files/file_table",
             :locals => { :files => [ photo ], :mode => :manage, :field_name => nil }

      img = Nokogiri::HTML(rendered).at_css("img.file-thumb-image")
      expect(img).to be_present
      expect(img["src"]).to include(game_file_delivery_path(photo.game, photo, "thumb"))
    end

    it "renders the generic indicator, not a broken <img>, for a PDF" do
      pdf = create_game_file(:game => @game, :filename => "карта.pdf", :content_type => "application/pdf")

      render :partial => "game_files/file_table",
             :locals => { :files => [ pdf ], :mode => :manage, :field_name => nil }

      expect(rendered).not_to include("<img")
      expect(rendered).to include(I18n.t("game_files.table.no_thumbnail"))
    end

    it "renders the generic indicator, not a broken <img>, for a file with no blob attached" do
      # existing_thumb_variant returns nil (not a raise) for a GameFile
      # record with no attachment at all -- the case Task 2 itself found and
      # fixed in GameFile#existing_thumb_variant. @file (top-level before
      # block) is exactly this: a GameFile row with no `.file.attach` ever
      # called on it.
      render :partial => "game_files/file_table",
             :locals => { :files => [ @file ], :mode => :manage, :field_name => nil }

      expect(rendered).not_to include("<img")
      expect(rendered).to include(I18n.t("game_files.table.no_thumbnail"))
    end
  end
end
