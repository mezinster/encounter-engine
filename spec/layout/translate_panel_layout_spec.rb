require "rails_helper"
require_relative "../support/layout_measurement"

# The AI-translation panel on the game edit screen, measured in a real browser.
#
# WHY: neither suite can see this. Capybara's rack_test driver parses no
# stylesheet, and a request spec sees markup only -- so "the buttons are in two
# columns" is a claim no ordinary test in this repository can make or refute.
# The panel shipped with NO css rule for either of its classes and rendered as a
# staircase, each row's button starting wherever that row's locale name happened
# to end, without a single test noticing.
describe "the translate panel, measured", :layout, type: :request do
  include LayoutMeasurement

  # Superadmin-only AND hidden without an API key, so both have to be true
  # before there is anything on the page to measure at all. The key is stubbed
  # at Client.configured? -- the same seam spec/requests/translation_runs_spec.rb
  # uses -- rather than by setting ENV, so no example here depends on the
  # developer's environment.
  before { allow(Translation::Client).to receive(:configured?).and_return(true) }

  let(:page_html) do
    admin = create_user
    admin.update!(:is_superadmin => true)
    game = create_game(:author => admin, :name => "Викторина",
                       :primary_locale => "ru", :available_locale_list => %w[ru])

    put login_path, :params => { :email => admin.email, :password => "1234" }
    get edit_game_path(game)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("translate-locales")
    response.body
  end

  PANEL_PROBE = <<~JS
    var buttons = Array.prototype.slice.call(
      document.querySelectorAll(".translate-locales button")
    );
    var lefts = buttons.map(function (b) {
      return Math.round(b.getBoundingClientRect().left);
    });
    var RESULT = {
      count: buttons.length,
      lefts: lefts,
      distinctLefts: lefts.filter(function (v, i, a) { return a.indexOf(v) === i; }).length,
      hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      // Proves the <li> is still a rendered box rather than having been folded
      // out of the box tree. The obvious CSS for this panel is
      // `li { display: contents }`, which is one line shorter and which all
      // three engines once punished by dropping the list's accessibility
      // semantics. That could not be checked from here -- chrome-headless-shell
      // exposes no computedRole and no --dump-accessibility-tree, so an
      // accessibility probe could report nothing but "unknown", which reads
      // like a pass. So the stylesheet uses subgrid instead, and this asserts
      // the difference: a display:contents <li> measures 0x0.
      liBoxes: Array.prototype.map.call(
        document.querySelectorAll(".translate-locales li"),
        function (li) {
          var r = li.getBoundingClientRect();
          return Math.round(r.width) > 0 && Math.round(r.height) > 0;
        }
      )
    };
  JS

  { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
    context "at #{width}x#{height} -- #{name}" do
      let(:m) { measure(page_html, width, height, PANEL_PROBE, :tmp_name => "translate-panel-measure.html") }

      # One button per non-primary locale: seven registered, minus ru.
      it "renders a button for every target locale" do
        expect(m["count"]).to eq(6)
      end

      # THE assertion. Every button starting at the same x is what "two columns"
      # means; a staircase is six different values.
      it "starts every button at the same x" do
        expect(m["distinctLefts"]).to eq(1)
      end

      it "does not overflow sideways" do
        expect(m["hOverflow"]).to eq(0)
      end

      # Guards the tempting one-line alternative. See the probe comment above:
      # `li { display: contents }` aligns the buttons just as well and takes the
      # list item out of the box tree to do it, which is an accessibility
      # question this harness cannot answer. If someone swaps subgrid for it,
      # this goes red rather than passing quietly.
      it "keeps every list item a real rendered box" do
        expect(m["liBoxes"]).to eq([ true ] * 6)
      end
    end
  end
end
