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

      # Not eq(6): that pins today's table count, so an ordinary documentation
      # edit that adds or removes a table would redden this spec for no
      # layout- or rendering-related reason. What this example actually
      # exists to prove is that the GFM parser is active at all -- >= 1 proves
      # that just as well and stays green across a content-only edit.
      it "renders the markdown tables as tables" do
        expect(doc.css("table").size).to be >= 1
      end

      # hard_wrap: the GFM parser defaults it to TRUE, which turns every single
      # newline into <br>. These manuals are hard-wrapped prose at ~85 columns,
      # so the default renders 158-189 spurious line breaks per file and every
      # paragraph keeps its authoring width instead of the browser's.
      it "emits no <br> for the source's own line wrapping" do
        expect(doc.css("br")).to be_empty
      end

      it "renders fenced code blocks as pre > code" do
        expect(doc.css("pre > code")).not_to be_empty
      end

      # app/views/manual/show.html.erb renders this HTML with `raw`, which is
      # correct only because the content is repository-authored and
      # PR-reviewed -- kramdown's GFM parser passes raw HTML straight through
      # (verified separately: <script> and an onclick attribute both survive
      # into the output), so `raw` is safe here only as long as the shipped
      # files contain none. That is a fact about the FILES, checkable
      # mechanically, not something to leave as an assertion in a comment.
      it "ships no raw HTML, which is what makes `raw` in the view safe" do
        expect(doc.css("script, style, iframe, object, embed")).to be_empty
        expect(doc.css("*").select { |node| node.attributes.keys.any? { |name| name.start_with?("on") } }).to eq([])
      end
    end
  end

  it "keeps the Cyrillic heading ids the manuals link to" do
    doc = Nokogiri::HTML5.fragment(Manual::Renderer.call(Rails.root.join("docs/manual/ru.md").read))

    expect(doc.css("[id]").map { |node| node["id"] })
      .to include("руководство-пользователя", "игроку", "файлы-и-изображения")
  end

  # The anchor-integrity examples above only check a document against
  # ITSELF: they collect ids and hrefs from the same render. ru.md links to
  # deployment.ru.md#6-первый-администратор, and nothing so far renders
  # deployment.ru.md to prove that id actually exists there -- a renamed
  # heading in the deployment guide would leave ru.md's link silently dead.
  #
  # Read the fragments straight off the markdown SOURCE with a regex, rather
  # than rendering and mapping the GitHub URLs the link pass produces back to
  # filenames: the source already names the file and the fragment side by
  # side, and the link pass's job (proven separately, above) is exactly to
  # turn that into a GitHub URL, so re-deriving it after the fact would only
  # be testing the same link pass twice.
  it "resolves every cross-file .md#fragment link to a real id in its target" do
    cross_file_link = /\]\(([^)\s]+\.md)#([^)\s]+)\)/
    checked = 0

    MANUAL_FILES.each do |path|
      path.read.scan(cross_file_link) do |target, fragment|
        target_path = path.dirname.join(target).cleanpath
        target_ids = Nokogiri::HTML5.fragment(Manual::Renderer.call(target_path.read))
          .css("[id]").map { |node| node["id"] }

        expect(target_ids).to include(fragment),
          "#{path.basename}'s link to #{target}##{fragment} has no matching id in #{target_path.basename}"
        checked += 1
      end
    end

    # Guards the guard: if the regex ever stopped matching anything (a
    # reformatted link, say), the loop above would pass vacuously.
    expect(checked).to be > 0
  end

  describe "the link pass" do
    def hrefs(markdown)
      Nokogiri::HTML5.fragment(Manual::Renderer.call(markdown))
        .css("a[href]").map { |a| a["href"] }
    end

    it "sends the other language's manual through the app's own locale switch" do
      expect(hrefs("Russian version: [ru.md](ru.md).")).to eq(["/manual?locale=ru"])
    end

    it "keeps a fragment when switching language" do
      expect(hrefs("[en](en.md#for-players)")).to eq(["/manual?locale=en#for-players"])
    end

    # The deployment guide has no route: its readers do not have a running
    # instance to read it on. GitHub renders it, with the anchors it was
    # written against.
    it "sends the deployment guide to GitHub, fragment intact" do
      expect(hrefs("[install](deployment.ru.md#6-первый-администратор)")).to eq(
        ["https://github.com/mezinster/encounter-engine/blob/master/docs/manual/deployment.ru.md#6-первый-администратор"]
      )
    end

    it "resolves a link that climbs out of docs/manual" do
      expect(hrefs("[restore](../runbooks/restore.md)")).to eq(
        ["https://github.com/mezinster/encounter-engine/blob/master/docs/runbooks/restore.md"]
      )
    end

    it "leaves in-page anchors and absolute URLs alone" do
      expect(hrefs("[a](#игроку) and [b](https://game.mezin.eu/)"))
        .to eq(["#игроку", "https://game.mezin.eu/"])
    end

    # [text]() -- an empty href -- is valid GFM and kramdown renders it as
    # <a href="">. A blank path is neither an in-app manual nor a .md link;
    # it must be left alone rather than raising.
    it "leaves an empty link href alone rather than raising" do
      expect { hrefs("[empty link]().") }.not_to raise_error
      expect(hrefs("[empty link]().")).to eq([""])
    end

    it "leaves a bare fragment-only href alone" do
      expect(hrefs("[jump](#)")).to eq(["#"])
    end

    it "leaves no relative .md link anywhere in the shipped manuals" do
      MANUAL_FILES.each do |path|
        relative = hrefs(path.read).reject do |href|
          href.start_with?("http://", "https://", "#", "mailto:")
        end

        expect(relative.grep(/\.md(#|\z)/)).to eq([]), "#{path.basename} still has a raw .md link"
      end
    end
  end
end
