require "rails_helper"
require_relative "../support/layout_measurement"

# The manual is the widest content this app renders: six tables, three columns,
# rows up to 135 characters, on a 390px phone. Neither suite can see it --
# Capybara's rack_test driver parses no stylesheet and a request spec sees
# markup only -- which is the same blind spot that let a play screen ship with
# its submit button below the fold.
#
# The property asserted here survives a redesign: whatever the tables look
# like, the PAGE must not be the thing that scrolls sideways.
describe "the manual, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:page_html) do
    get manual_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  MANUAL_PROBE = <<~JS
    var tables = Array.prototype.slice.call(document.querySelectorAll(".manual table"));
    var RESULT = {
      tables: tables.length,
      hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      // A table that scrolls inside itself is the point; one that does not
      // overflow at all at this width would mean the measurement found no
      // real content.
      scrollableTables: tables.filter(function (t) {
        return t.scrollWidth > t.clientWidth;
      }).length,
      widestTableWithinPage: tables.every(function (t) {
        return t.getBoundingClientRect().width <= document.documentElement.clientWidth;
      })
    };
  JS

  it "never scrolls the page sideways on a phone" do
    result = measure(page_html, 390, 660, MANUAL_PROBE, :tmp_name => "manual-390.html")

    # Not eq(6): the exact table count is pinned in
    # spec/services/manual/renderer_spec.rb, where a change to it belongs. This
    # spec only needs to know the measurement found real content -- it must go
    # red for a LAYOUT reason (overflow), never because someone added or
    # removed a table in docs/manual/ru.md.
    expect(result["tables"]).to be > 0
    expect(result["hOverflow"]).to eq(0)
    expect(result["widestTableWithinPage"]).to be(true)
    expect(result["scrollableTables"]).to be > 0
  end

  it "never scrolls the page sideways on a narrow phone" do
    result = measure(page_html, 375, 553, MANUAL_PROBE, :tmp_name => "manual-375.html")

    expect(result["hOverflow"]).to eq(0)
  end

  it "still fits on a desktop" do
    result = measure(page_html, 1280, 800, MANUAL_PROBE, :tmp_name => "manual-1280.html")

    expect(result["hOverflow"]).to eq(0)
    # hOverflow alone is close to unfailable here: .manual { max-width: 70ch }
    # measures at 791px on a 1280px window, so the page has never been the
    # thing under pressure at this size -- a table is. Prose-heavy manual
    # tables should fit inside that measure rather than scroll on a monitor
    # this wide.
    expect(result["scrollableTables"]).to eq(0)
  end

  # base.css:64's `.main > * + * { margin-top: var(--space-4) }` only reaches
  # DIRECT children of .main. The manual is the first view to wrap its
  # content in its own element (`<div class="manual">`), which puts every
  # rendered block one level too deep for that rule to see -- so without a
  # rule scoped to .manual itself, base.css:4-7's zeroed margins and base.css
  # :55's `ul { list-style: none }` stand exactly as written: flush headings,
  # bullet lists indistinguishable from prose. Neither suite can see this --
  # Capybara's rack_test driver parses no stylesheet, and a request spec sees
  # markup only -- so this is the only place it can be pinned.
  RHYTHM_PROBE = <<~JS
    var manual = document.querySelector(".manual");
    var blocks = Array.prototype.slice.call(manual.querySelectorAll(":scope > *"));
    var gaps = [];
    for (var i = 1; i < blocks.length; i++) {
      gaps.push(blocks[i].getBoundingClientRect().top - blocks[i - 1].getBoundingClientRect().bottom);
    }
    var paragraphs = Array.prototype.slice.call(manual.querySelectorAll("p"));
    // A "p + p" pair: the second paragraph in some adjacent run, so its
    // margin-top is attributable only to the CSS rule, never to a heading's
    // larger margin-top bleeding in above it.
    var secondOfPair = paragraphs.filter(function (p) {
      return p.previousElementSibling && p.previousElementSibling.tagName === "P";
    })[0];
    var pStyle = getComputedStyle(paragraphs[0]);
    var ul = manual.querySelector("ul");
    var RESULT = {
      pMarginTop: secondOfPair ? parseFloat(getComputedStyle(secondOfPair).marginTop) : null,
      ulListStyleType: ul ? getComputedStyle(ul).listStyleType : null,
      // The gap between two blocks with NO margin between them is not
      // necessarily 0 -- a line box's half-leading still separates the text
      // from the box edge. The broken page measured 0, 9 and 18px this way;
      // none of those is a real paragraph gap, so the assertion below is
      // against the leading, not against 0.
      minGap: gaps.length ? Math.min.apply(null, gaps) : null,
      leading: parseFloat(pStyle.lineHeight) - parseFloat(pStyle.fontSize)
    };
  JS

  it "gives the document a real vertical rhythm, not just leading" do
    result = measure(page_html, 390, 660, RHYTHM_PROBE, :tmp_name => "manual-rhythm.html")

    expect(result["pMarginTop"]).to be > 0
    expect(result["ulListStyleType"]).not_to eq("none")
    expect(result["minGap"]).to be > result["leading"]
  end
end
