require "rails_helper"
require_relative "../support/layout_measurement"

# The superadmin console, measured in a real browser in both themes. Excluded
# from the default run (needs chrome-headless-shell); LAYOUT_SPECS=1. A missing
# browser raises. Tasks 8 and 11 of the 2026-10-05 plan add the games list,
# the game page, the user page and the teams list to this file.
describe "the superadmin console, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def superadmin_html(path)
    put login_path, :params => { :email => superadmin.email, :password => "1234" }
    get path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def measure_admin(html, width, height, theme, body)
    measure(html, width, height, <<~JS, :tmp_name => "admin-console-measure.html")
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var vw = document.documentElement.clientWidth;
      #{body}
    JS
  end

  TABS_PROBE = <<~JS
    var links = Array.prototype.slice.call(document.querySelectorAll(".admin-tabs a"));
    var RESULT = {
      count: links.length,
      clipped: links.filter(function (a) { var r = a.getBoundingClientRect(); return r.left < 0 || r.right > vw; }).map(function (a) { return a.textContent; }),
      barScrolls: (function (n) { return n.scrollWidth > n.clientWidth + 1; })(document.querySelector(".admin-tabs")),
      shortTabs: links.filter(function (a) { return a.getBoundingClientRect().height < 43.5; }).map(function (a) { return a.textContent; }),
      hOverflow: document.documentElement.scrollWidth - vw
    };
  JS

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "laptop" => [ 845, 700 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "tabs, #{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure_admin(superadmin_html(admin_dashboard_path), width, height, theme, TABS_PROBE) }

        # Wrapping is allowed; hiding is not. A bar that scrolled sideways hid
        # half the tabs at 845-1024px, where this console is mostly used.
        it "shows all eight tabs, full-size, none clipped, without widening the page" do
          expect(m["count"]).to eq(8)
          expect(m["clipped"]).to eq([])
          expect(m["barScrolls"]).to be(false)
          expect(m["shortTabs"]).to eq([])
          expect(m["hOverflow"]).to be <= 0
        end
      end
    end
  end
end
