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

    def self.call(markdown)
      Kramdown::Document.new(markdown, OPTIONS).to_html
    end
  end
end
