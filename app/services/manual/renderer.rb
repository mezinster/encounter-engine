# app/services/manual/renderer.rb
#
# The user manual's markdown, as HTML.
#
# Deliberately knows nothing about locales or the filesystem -- Manual::Source
# decides WHICH document this is, and this decides what it looks like. That
# split is what lets sub-project B replace the source with database-backed
# translations without touching rendering.
#
# Heading ids come from kramdown's auto_ids, which was measured against all
# four real manuals before this was written: it produces exactly the anchors
# the files were authored against, in both alphabets. See the design doc §2.1
# and spec/services/manual/renderer_spec.rb, which is the thing that would
# notice if that ever stopped being true.
module Manual
  class Renderer
    # hard_wrap is the option that matters. The GFM parser defaults it to true,
    # which renders every newline in the source as <br> -- and these files are
    # hard-wrapped prose, so the default produced 189 spurious breaks in en.md
    # alone and pinned every paragraph to its authoring width.
    OPTIONS = { :input => "GFM", :hard_wrap => false }.freeze

    # Where a relative .md link points once it is on the web. Pinned to master
    # rather than to the running commit: a reader following a link out of the
    # manual wants the current document, and this app has no way to know which
    # commit built it.
    GITHUB_BLOB = "https://github.com/mezinster/encounter-engine/blob/master/".freeze

    # The directory the manuals live in, which is what a relative link is
    # relative TO. Not Rails.root: this resolves link text, not files on disk.
    DOCUMENT_ROOT = "docs/manual".freeze

    # The two documents this app serves itself. Everything else goes to GitHub.
    IN_APP = { "ru.md" => :ru, "en.md" => :en }.freeze

    def self.call(markdown)
      document = Nokogiri::HTML5.fragment(
        Kramdown::Document.new(markdown, OPTIONS).to_html
      )
      rewrite_links(document)
      document.to_html
    end

    # Relative markdown links are correct in a repository and meaningless in a
    # browser. ru.md/en.md become the app's own route WITH ?locale=, so that
    # following one goes through LocaleSelection and is remembered in the
    # session -- exactly as if the header switcher had been used. Anything else
    # ending in .md is resolved against docs/manual and handed to GitHub.
    def self.rewrite_links(document)
      document.css("a[href]").each do |anchor|
        href = anchor["href"]
        next if href.empty? || href.start_with?("#", "http://", "https://", "mailto:")

        path, fragment = href.split("#", 2)
        suffix = fragment ? "##{fragment}" : ""

        if (locale = IN_APP[path])
          anchor["href"] =
            "#{Rails.application.routes.url_helpers.manual_path(:locale => locale)}#{suffix}"
        elsif path.end_with?(".md")
          resolved = Pathname.new(DOCUMENT_ROOT).join(path).cleanpath
          anchor["href"] = "#{GITHUB_BLOB}#{resolved}#{suffix}"
        end
      end
    end
    private_class_method :rewrite_links
  end
end
