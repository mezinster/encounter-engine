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

    expect(result["tables"]).to eq(6)
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
  end
end
