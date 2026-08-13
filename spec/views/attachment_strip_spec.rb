require "rails_helper"

# shared/_attachment_strip.html.erb -- the play-screen strip rendered below
# a level's task text and inside each fired hint's fieldset (Task 3). Three
# invariants this file exists to pin, each one lifted straight from the
# design's hard rules:
#
#   1. NEVER web_variant/thumb_variant -- those GENERATE a variant on a miss,
#      and a render path that allocates disk breaks design invariant I1 (a
#      full disk must not break the play screen mid-race). Only a real,
#      already-processed blob can prove this: a blob-less fixture makes the
#      GENERATING method raise, which would pass the "zero variants created"
#      assertion for the wrong reason (nothing rendered at all).
#   2. GameFileAccess#permitted? is asked before any tag is emitted -- a file
#      the requester may not see renders nothing, not a broken link.
#   3. An image with an existing "web" variant renders <img>; a PDF, and an
#      image whose variant record is missing, both render <a> with the
#      generic indicator, never a broken <img>.
describe "shared/attachment_strip", :type => :view do
  before(:each) do
    view.define_singleton_method(:current_user) { @current_user }
  end

  def render_strip(files, game)
    render :partial => "shared/attachment_strip", :locals => { :files => files, :game => game }
  end

  describe "an attached image with an existing web variant" do
    it "renders an <img> whose src is the delivery path at the web variant, linked to the original" do
      author = create_user
      game = create_game(:author => author)
      photo = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
      expect(photo).to be_persisted # sanity: a real blob, real variants

      @current_user = author # author_or_superadmin? short-circuits permitted? to true
      render_strip([ photo ], game)

      doc = Nokogiri::HTML(rendered)
      img = doc.at_css("img.attachment-image")
      expect(img).to be_present
      expect(img["src"]).to include(game_file_delivery_path(game, photo, "web"))
      # Alt text is the filename -- author content, never t().
      expect(img["alt"]).to eq(photo.filename)

      link = doc.at_css("a.attachment-item")
      expect(link).to be_present
      expect(link["href"]).to include(game_file_delivery_path(game, photo, "original"))
    end

    # Hard rule 1: prove existing_web_variant is what's actually called, not
    # web_variant, by making the GENERATING method the one that would fail
    # loudly if it were reached -- wiping every VariantRecord and asserting
    # the count stays at zero after render. A fixture with NO blob at all
    # would make web_variant raise (ActiveStorage::FileNotFoundError or
    # similar) rather than generate, which would pass this assertion for the
    # wrong reason -- hence the real, already-uploaded photo.
    it "creates NO ActiveStorage::VariantRecord while rendering, even when one is missing" do
      author = create_user
      game = create_game(:author => author)
      photo = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
      expect(ActiveStorage::VariantRecord.count).to be > 0 # uploaded eagerly -- sanity

      ActiveStorage::VariantRecord.delete_all
      expect(photo.existing_web_variant).to be_nil # confirms the miss this test is about

      @current_user = author
      expect {
        render_strip([ photo ], game)
      }.not_to change { ActiveStorage::VariantRecord.count }
      expect(ActiveStorage::VariantRecord.count).to eq(0)

      # And the render degraded to the generic indicator, not a broken <img>.
      doc = Nokogiri::HTML(rendered)
      expect(doc.at_css("img")).to be_nil
      expect(doc.at_css("a.attachment-item--generic")).to be_present
      expect(rendered).to include(photo.filename)
    end
  end

  describe "a PDF" do
    it "renders a link with the generic indicator, never an <img>" do
      author = create_user
      game = create_game(:author => author)
      pdf = GameFileUpload.new(game, fixture_upload("map.pdf"), author).call
      expect(pdf).to be_persisted

      @current_user = author
      render_strip([ pdf ], game)

      doc = Nokogiri::HTML(rendered)
      expect(doc.at_css("img")).to be_nil
      link = doc.at_css("a.attachment-item--generic")
      expect(link).to be_present
      expect(link["href"]).to include(game_file_delivery_path(game, pdf, "original"))
      expect(rendered).to include(pdf.filename)
    end
  end

  describe "authorization" do
    it "renders nothing for a file the requester may not see" do
      author = create_user
      game = create_game(:author => author)
      photo = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call

      # No team, no passing, not the author, not a superadmin -- permitted?
      # refuses (GameFileAccess#passing_for_game returns nil for a
      # teamless user).
      @current_user = create_user
      render_strip([ photo ], game)

      expect(rendered.strip).to be_empty
      expect(rendered).not_to include("attachment-strip")
      expect(rendered).not_to include(photo.filename)
    end
  end

  describe "an empty list" do
    it "renders no empty container" do
      author = create_user
      game = create_game(:author => author)

      @current_user = author
      render_strip([], game)

      expect(rendered.strip).to be_empty
      expect(rendered).not_to include("attachment-strip")
    end
  end
end
