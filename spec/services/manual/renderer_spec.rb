require "rails_helper"

# Renders the SHIPPED manuals, not a fixture, and that is the point.
#
# The risk this file exists for is a heading whose generated id stops matching
# the ](#anchor) written to point at it -- and the damage is invisible: the
# page renders, the link is clickable and styled, the browser scrolls nowhere,
# nothing raises. Only the real documents can demonstrate it.
#
# Measured on 2026-08-22 (see the design doc, §2.1): kramdown 2.5.2 produces
# руководство-пользователя, установка and 6-первый-администратор, with zero
# dead anchors across all four files. Nothing guarantees it keeps agreeing with
# GitHub on headings these files do not yet contain, which is why this is a
# test rather than a comment.
MANUAL_FILES = Rails.root.glob("docs/manual/*.md").sort.freeze

describe Manual::Renderer do
  it "is looking at all four manuals" do
    expect(MANUAL_FILES.map { |path| path.basename.to_s })
      .to eq(%w[deployment.en.md deployment.ru.md en.md ru.md])
  end

  MANUAL_FILES.each do |path|
    context path.basename.to_s do
      let(:doc) { Nokogiri::HTML5.fragment(Manual::Renderer.call(path.read)) }
      let(:ids) { doc.css("[id]").map { |node| node["id"] } }

      it "resolves every internal anchor" do
        wanted = doc.css("a[href^='#']").map { |a| a["href"].delete_prefix("#") }.uniq

        expect(wanted - ids).to eq([])
      end

      it "gives every heading a distinct id" do
        expect(ids.tally.select { |_id, count| count > 1 }).to eq({})
      end

      it "renders the markdown tables as tables" do
        expect(doc.css("table").size).to eq(6)
      end

      # hard_wrap: the GFM parser defaults it to TRUE, which turns every single
      # newline into <br>. These manuals are hard-wrapped prose at ~85 columns,
      # so the default renders 158-189 spurious line breaks per file and every
      # paragraph keeps its authoring width instead of the browser's.
      it "emits no <br> for the source's own line wrapping" do
        expect(doc.css("br")).to be_empty
      end
    end
  end

  it "keeps the Cyrillic heading ids the manuals link to" do
    doc = Nokogiri::HTML5.fragment(Manual::Renderer.call(Rails.root.join("docs/manual/ru.md").read))

    expect(doc.css("[id]").map { |node| node["id"] })
      .to include("руководство-пользователя", "игроку", "файлы-и-изображения")
  end
end
